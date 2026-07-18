---
title: "Turning the sources into a workflow"
date: 2026-07-17
category: desarrollo
tags: [ruby, ai, nexo, workflows]
series: "Building an email agent with Nexo"
part: 4
---

# Turning the sources into a workflow

At this point the source catalog has three inboxes, each read by an agent. But
nothing runs them together, there is no single result, and if one of them fails I
find out by reading a stack trace. A triage run is really a job: read
what is available, record what happened, and produce one output. That is what
`Nexo::Workflow` is for.

A workflow is the second thing Nexo adds on top of `ruby_llm`. Where an agent is a
chat that accumulates context, a workflow is a finite job that fires and finishes,
and leaves behind a run record: a run id, a status, a result, and an ordered event
log you can read back. This post wraps the three sources in one workflow that stays
resilient when a source is missing or fails.

## The shape of a workflow

You subclass `Nexo::Workflow`, implement `#call(payload)`, and start it with `.run`.
Here is the triage workflow. It owns no source list of its own — it walks the
`Sources` catalog from [Part 3](03-tools-imap-cli.md), so a new inbox is a
descriptor, and the orchestration never changes:

```ruby
module NexoMail
  module Workflows
    class MultiInboxTriage < Nexo::Workflow
      def call(_payload)
        available, skipped = partition_sources
        skipped.each { |name, reason| emit(:source_skipped, source: name, reason: reason) }

        produced = available.map { |_name, descriptor|
          extract_source(descriptor)
        }.compact.to_h

        {sources: produced.keys, skipped: skipped}
      end
    end
  end
end
```

`#call` returns a plain hash, which becomes the run's `result`. Running it is one
line:

```ruby
run = NexoMail::Workflows::MultiInboxTriage.run
run.status   # "done"
run.result   # {"sources" => ["Gmail", "HEY"], "skipped" => {"Apple Mail" => "..."}}
```

The `run` object is the value of the whole thing. It has a stable id, a status, the
result, and the event log. That is the difference from calling an agent directly:
an agent gives you a response; a workflow gives you an inspectable record of a job.

## Deciding what can run

Before running anything, the workflow checks which sources are actually usable.
Each descriptor already knows how to answer that, through an `available?` method
that returns `nil` when it can run or a short reason when it cannot:

```ruby
def partition_sources
  available = {}
  skipped   = {}
  Sources.all.each do |descriptor|
    reason = descriptor.available?     # nil, or a reason string
    reason ? (skipped[descriptor.name] = reason) : (available[descriptor.name] = descriptor)
  end
  [available, skipped]
end
```

The Gmail descriptor's check returns a reason if the address or app password is not
configured. The HEY descriptor's checks that the `hey` binary is on the path and
authenticated. A source that cannot run is skipped with its reason recorded,
and it never enters the run. This is what keeps a missing credential or an
uninstalled CLI from turning into a crash. The run adapts to whatever is available
on the machine.

## Running a source, and recording what happened

Each available source is run inside a small method that builds its agent from the
descriptor, prompts it, and records the outcome:

```ruby
def extract_source(descriptor)
  emit(:source_started, source: descriptor.name)
  agent = descriptor.build(cwd: Config.sandbox_dir)
  agent.prompt("Triage this inbox and write the JSON array to `#{descriptor.file}`.", max_turns: 30) do |type, payload|
    emit(:"agent_#{type}", source: descriptor.name, info: payload.to_s[0, 200])
  end
  emit(:source_done, source: descriptor.name)
  [descriptor.name, descriptor.file]
rescue => e
  emit(:source_failed, source: descriptor.name, error: e.message)
  nil
ensure
  agent&.close
end
```

`descriptor.build` returns an `EmailSource` for Gmail and HEY, or an
`AppleMailSource` for Apple Mail — the workflow does not care which; it only calls
the descriptor's interface.

The `emit` calls are the point. `emit(type, data)` appends an event to the run's
log, persisted as it goes. The block passed to `agent.prompt` receives every tool
call and result from the agent, and those get forwarded into the same log with an
`agent_` prefix. So the workflow's event log ends up holding the whole story of the
run: which sources started, every tool the agents called, which sources finished,
and which failed and why.

You read the log back with `Nexo::Workflow.logs`:

```ruby
Nexo::Workflow.logs(run.id) do |event|
  type = event["type"]
  data = event["data"]
  puts "#{type}: #{data.inspect}"
end
```

In `nexo_mail` this is exactly what the command line UI reads to print the
per-source summary, the check marks and the skip reasons. The UI is not guessing at
progress; it is replaying the event log.

## Failure is part of the design

A source that raises mid-run is caught, recorded as a failed event, and the run
continues with whatever the other sources produced. That is the `rescue` in
`extract_source`. A skipped source, a failed source, and a successful source all
end the same way: an event in the log, and the run reaching `done`. A single
flaky inbox never sinks the run.

There is one subtlety worth being explicit about, because it is the opposite of the
tool convention from Part 3. Tools return `{error: ...}` and never raise. Workflows
do the reverse: an unhandled exception in `#call` is recorded as a `failed` status
and then re-raised. That is deliberate. A tool failure is context for the model to
work around; a workflow failure is a job that did not complete, and you want to
know. Inside `#call` you decide which errors to catch and turn into recorded,
recoverable outcomes (a failed source) and which to let propagate (the whole run is
broken). In `nexo_mail` the per-source failures are caught, so the run itself
almost always reaches `done`.

## Where the workflow ends and the agent begins

The division of labor is clean. The workflow decides which agents run and in what
order, and records what happened. The agents do the reading and classifying. The
workflow reads no mail and makes no classification decision; the agents own none of
the orchestration.

Nexo also offers a built-in helper, `run_agent`, for the common case where a
workflow drives a single declared agent bound to the run's own sandbox, forwarding
its events for you. `nexo_mail` does not use it, because it runs several different
agent classes across its stages, so it instantiates each one and forwards events by
hand, as above. For a workflow with one agent, `run_agent` is the shorter path and
worth knowing.

## Where this leaves us

There is now one workflow that runs the available sources, records everything in an
event log, and produces a result, while shrugging off missing and failing sources.
But it runs the sources one after another. Since most of the time is the model
thinking, running three inboxes in sequence is roughly three times slower than it
needs to be. The next post makes the fan-out concurrent, with a bound, using one
Nexo call and no hand-rolled threads.

## What will trip you up

Read the result back as string-keyed. `#call` receives a symbol-keyed payload, but
the stored `payload` and `result` come back string-keyed, because they round-trip
through JSON. If you write `run.result[:sources]` you will get `nil`; use
`run.result["sources"]`.

Workflows re-raise; tools do not. Catch the errors you want to become recorded,
recoverable outcomes inside `#call`. Anything you let escape marks the run failed
and propagates.

Close the agents you instantiate. When you run agents by hand inside a workflow,
each one holds resources (an MCP subprocess, an IMAP connection). Close them in an
`ensure`, as `extract_source` does.

A crashed worker leaves a run stuck. If the process dies mid-run, the run stays in
a running state, because nothing marked it finished. Nexo ships
`reconcile_interrupted!` to sweep those at boot. It matters once you move this off
your laptop and onto a background queue, which is a later post.

Next: [Part 5, running the sources concurrently](05-concurrency.md).
