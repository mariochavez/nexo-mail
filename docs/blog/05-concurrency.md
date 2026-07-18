---
title: "Running the sources concurrently"
date: 2026-07-17
category: desarrollo
tags: [ruby, ai, nexo, concurrency, async]
series: "Building an email agent with Nexo"
part: 5
---

# Running the sources concurrently

The workflow from [Part 4](04-workflows.md) runs the three sources one after
another. Each source spends almost all of its time waiting on the model to think,
so running them in sequence means the total time is roughly the sum of three model
conversations. There is no reason for that. The three inboxes are independent; they
should run at the same time.

This is the kind of thing that is easy to get wrong by hand. Threads, a thread
pool, collecting results in order, deciding what happens when one of them fails,
and keeping the whole thing from hammering a rate-limited API. Nexo provides a
single call for it: `Nexo.concurrent`. This post uses it to fan the sources out,
with a bound, and keeps the sequential path as a fallback.

## The concurrency Nexo actually adds

It is worth being precise about what `Nexo.concurrent` is for, because it is not
raw parallelism. LLM calls are I/O bound, and under Ruby's fiber scheduler an
in-flight model request already yields to others. What you actually need for a
fan-out is not more parallelism, it is a bound: a way to run many tasks at once
without launching an unbounded number and tripping a provider rate limit.

`Nexo.concurrent` gives you exactly that. It runs every task you add inside one
`async` reactor, capped by a semaphore, coordinated by a barrier, and returns the
results in submission order. The first error is re-raised and the remaining tasks
are stopped. You get bounded fan-out and ordered results without touching a thread
primitive.

Async is opt-in. Nexo runs perfectly well synchronously with no `async` gem
installed, and only complains when you reach for a fan-out feature. So the gem is a
dependency you add when you want this, not one you carry by default.

## Fanning out the sources

Here is the workflow's source stage, rewritten to run concurrently:

```ruby
def fan_out_sources(sources)
  return {} if sources.empty?

  pairs =
    begin
      Nexo.concurrent(max_in_flight: sources.size) do |c|
        sources.each { |name, (klass, file)| c.add { extract_source(name, klass, file) } }
      end
    rescue Nexo::MissingDependencyError => e
      emit(:async_unavailable, error: e.message)
      sources.map { |name, (klass, file)| extract_source(name, klass, file) }
    end

  pairs.compact.to_h
end
```

`Nexo.concurrent` takes a block and yields a collector. Each `c.add { ... }`
registers a task, and the block's return value is the array of task results in the
order you added them. So `extract_source` is unchanged from Part 4; the only
difference is that the three calls now overlap. `max_in_flight` caps how many run
at once. Here it is set to the number of sources, because three is small. With more
sources, or several accounts of the same kind, you would set it to whatever keeps
you under your rate limit rather than launching all of them.

The `rescue` is deliberate. If the `async` gem is not installed, `Nexo.concurrent`
raises `Nexo::MissingDependencyError`. Rather than making async a hard requirement,
the workflow catches that, records an event noting it fell back, and runs the
sources sequentially with a plain `map`. The tool works either way; installing
`async` just makes the multi-inbox case faster.

`extract_source` already returns `[name, file]` on success and `nil` on failure, so
`compact.to_h` drops the failed sources and gives back a clean map of what was
produced. The concurrency did not change the result shape.

## Configuring it

Two settings in `Nexo.configure` govern this:

```ruby
Nexo.configure do |config|
  config.concurrency   = :async   # :threaded (default) or :async
  config.max_in_flight = 8        # default bound for Nexo.concurrent
end
```

`concurrency` chooses the execution model. Under `:async`, there is a useful
detail: the `:local` sandbox offloads its blocking file and shell operations to a
worker thread, so they do not stall the fiber reactor while other tasks are in
flight. Under `:threaded`, work runs inline with no reactor. `max_in_flight` is the
default bound when you do not pass one to `Nexo.concurrent`.

There is also `buffer_workflow_events`, and a per-run `buffer_events: true` option
on `.run`. Normally each `emit` is persisted as it happens. When many tasks are
emitting events concurrently, buffering collects them and flushes once at the end,
which cuts write pressure. For the terminal tool it does not matter; it matters
when you move this onto a shared database, which comes up in the shipping post.

## The same call scales past three inboxes

Three fixed sources is the small case. `Nexo.concurrent` is the same tool for the
larger one. If you had a list of Gmail accounts to triage, you would fan a whole
workflow run out per account, bounded so you stay polite to the API:

```ruby
results = Nexo.concurrent(max_in_flight: 5) do |c|
  accounts.each do |account|
    c.add { MultiInboxTriage.run(account_id: account.id).result }
  end
end
```

Each `c.add` runs a full workflow, and the results come back in account order. The
bound of five means at most five accounts are being triaged at once, no matter how
long the list is. This is the pattern for turning a single-user tool into a
multi-account one without writing a scheduler.

## Where this leaves us

The sources now run concurrently, bounded, with a sequential fallback, and the
result is unchanged. The workflow is doing real orchestration. But I have been
glossing over something the source agents rely on: they write their JSON output
into a workspace, and I have said "the `:local` sandbox" without explaining what
that is or why writing into it is safe. That is the next post: the sandbox and
permission seams, which are the two things that make read-only mail an enforced
property rather than a hope.

## What will trip you up

`Nexo.concurrent` needs the `async` gem. Without it you get
`Nexo::MissingDependencyError`. Either add the gem or catch the error and fall back
to a sequential path, as the workflow does. Do not make async a silent hard
requirement of a tool people install.

Wrapping a single agent call in `Async {}` buys nothing. Async only pays off across
a fan-out. One `agent.prompt` in a reactor is the same speed as one `agent.prompt`
without it.

`max_in_flight` is the rate-limit knob, not a performance dial. Set it to the
number of concurrent requests your provider tolerates, not to the biggest number
your machine can run. Overshooting it is how you get throttled.

Watch the database connection pool under a fiber server. If you later run this
under a fiber-based server and each concurrent task touches the database, you can
exhaust the connection pool. Raise the pool size and prefer buffered events. This
does not come up on a laptop, but it does in production.

Next: [Part 6, the sandbox and permission seams](06-sandbox-permissions.md).
