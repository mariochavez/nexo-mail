---
title: "Agent is Model plus Harness: getting to know Nexo"
date: 2026-07-17
category: desarrollo
tags: [ruby, ai, nexo, ruby_llm, ollama]
series: "Building an email agent with Nexo"
part: 0
---

# Agent is Model plus Harness: getting to know Nexo

I read email in three places. Apple Mail for personal things, Gmail for work,
and HEY for the newsletters and receipts I like to keep at arm's length. Keeping
up with all three had turned into its own small job, and most of what filled them
did not need me at all.

What I wanted was easy to describe. A tool that reads all three inboxes, tells me
what actually needs my attention, and cannot touch a single message. Read-only,
running on my own machine, against a local model so nothing about my mail ever
leaves the laptop.

That tool is `nexo_mail`, and I built it with Nexo. Over this series I am going to
build it again, out loud, one piece at a time. Each post adds one capability, and
with it one Nexo feature you will reach for in your own agents. This first post is
the groundwork: what Nexo is, why it exists, and the first agent running on a
local model.

## A model is only half of an agent

A language model on its own is an odd thing to build on. It reasons well about
whatever you put in front of it, and then it forgets all of it the moment it
answers. It cannot read your files, call your APIs, remember what it did a minute
ago, or be stopped from doing something you did not ask for.

Everything you add to make a model useful and safe is the harness. The tools it
can call. The instructions that shape how it works. The gate that decides what it
is allowed to do. The sandbox it writes into. The loop that runs model, tool,
model until there is a real answer.

That is what [Nexo](https://rubygems.org/gems/nexo_ai) (the `nexo_ai` gem) is: a
harness for a model. The phrase the project uses for it is "Agent is Model plus
Harness." Each post in this series adds one part of that harness.

## What Nexo is, and what it deliberately leaves alone

Ruby already has a good LLM stack. [`ruby_llm`](https://github.com/crmne/ruby_llm)
gives you the chat and tool loop, and around it sit `ruby_llm-skills`,
`ruby_llm-mcp`, and `ruby_llm-schema` for skills, the Model Context Protocol, and
structured output. Nexo's first decision is to not rebuild any of that. It
composes those gems behind one front door and adds only the two pieces the
ecosystem was missing:

The first is a sandbox and permissions seam. A pluggable place where the agent's
tools run (in memory, on the local filesystem, or inside a container) with an
explicit gate in front of every capability. The default is the safest one it
could pick: an in-memory sandbox with read-only permissions, so a model you do
not trust has no access to your machine until you say otherwise.

The second is a workflow lifecycle. A finite job with a run id, a status, a
result, and an event log you can read back. It is what you want when an agent's
work is a job you need to watch, resume, or schedule, rather than a chat.

If you remember those two additions, the rest of Nexo is glue and good defaults.
I find that framing useful because it tells you where to look: if something feels
missing, it is probably living in one of the `ruby_llm` gems, not in Nexo.

## Installing and configuring the harness

You add the gem the usual way:

```ruby
# Gemfile
gem "nexo_ai"
```

Nexo works in plain Ruby, with no Rails loaded. You configure the harness once,
in one place, and the defaults are safe and provider neutral. There is no
hardcoded model anywhere in Nexo, on purpose:

```ruby
require "nexo"

Nexo.configure do |config|
  config.default_model       = ENV["NEXO_MODEL"] # provider neutral, no default
  config.default_sandbox     = :virtual          # in memory, zero host access
  config.default_permissions = :read_only        # cannot write, shell, or fetch
  config.skills_path         = "app/skills"       # where SKILL.md packages live
  config.concurrency         = :threaded          # :threaded or :async, later
end
```

Credentials are a separate matter. `ruby_llm` owns them through its own
`RubyLLM.configure`, so `NEXO_MODEL` only names which model to run. It does not
authenticate anything. That separation matters later, but for now it means the
easiest way to start is a local model, where there is nothing to authenticate at
all.

## An agent in five lines

An agent in Nexo is a subclass of `Nexo::Agent` where you declare the pieces of
the harness with class macros. Here is the example the docs open with, a read-only
code reviewer:

```ruby
require "nexo"

class CodeReviewer < Nexo::Agent
  model       ENV.fetch("NEXO_MODEL")   # any ruby_llm model
  sandbox     :local                    # the real filesystem, guarded to cwd
  permissions :read_only                # can read, never write or run shell

  instructions "You are a careful code reviewer. Read files and report issues. Do not write files."
end

CodeReviewer.new(cwd: "/path/to/repo").prompt("Review the auth module")
```

I want to point at what is not here. There is no tool object wired by hand, no
permission plumbing, no vendor SDK, and no loop. You named a model, chose where
its tools run, set a permission mode, and wrote the instructions. The macros are
the harness.

The defaults matter for what comes next. Drop the `sandbox` and `permissions`
lines and you get `:virtual` and `:read_only`, an agent with no host access. You
opt into capability rather than opting out of it. For a tool that reads a real
email account, starting from no access is the right default.

## Running it on a local model

For this whole series I use [Ollama](https://ollama.com), so everything runs
offline and free. There is one wrinkle worth learning now, because it catches
everyone the first time.

`ruby_llm` normally checks a model id against its bundled registry and infers the
provider from it. A local Ollama tag like `gemma3:12b` is not in that registry.
So you tell Nexo the provider yourself and turn the lookup off:

```ruby
class LocalTriage < Nexo::Agent
  model               "gemma3:12b"
  provider            :ollama         # required once the registry lookup is off
  assume_model_exists true            # skip the models.json validation

  instructions "You summarize text crisply."
end

puts LocalTriage.new.prompt("Summarize: our Q3 numbers beat plan by 8%.").content
```

```sh
ollama pull gemma3:12b
NEXO_MODEL=gemma3:12b ruby first_agent.rb
```

If that prints a one-line summary, the harness is alive. That is the whole
foundation. Everything else in this series is adding capability to an agent shaped
almost exactly like this one.

## Where this is headed

From here the inbox tool grows one capability per post:

- Reading a real inbox over MCP, read only by construction (next post).
- Skills, which move the triage rules out of Ruby and into Markdown a non-Ruby
  collaborator can own.
- More inboxes, over IMAP and a CLI, so we meet Nexo's other tool shape.
- Workflows, which turn a pile of agents into a finite, observable job.
- Then concurrency, the safety model in detail, a synthesis step, a skill that
  ships its own template and script, human approved actions, and finally shipping
  the whole thing as a CLI, a gem, and a Rails job.

By the end there is a working tool, and it will have used most of Nexo, each
feature introduced at the point the tool actually needed it.

## What will trip you up

Two things bite people at this stage, and both are cheap to avoid.

The first is `assume_model_exists` without a `provider`. If you skip the registry
lookup, `ruby_llm` has no way to infer a provider, and Nexo raises a
`ConfigurationError`. Always set the two together. And only reach for
`assume_model_exists` when the model really is unregistered, like a local tag, a
self-hosted build, or a release newer than your gems. On a normal hosted id it
quietly disables a real typo catcher.

The second is expecting `NEXO_MODEL` to do more than it does. It names the model,
it does not authenticate it. A correctly named hosted model with no matching
`RubyLLM.configure` credential raises from inside `ruby_llm` at request time, not
from Nexo, and not when you construct the agent. Starting on local Ollama sidesteps
this entirely, which is why I start there.

Next up I point this same shape of agent at a real Apple Mail inbox, and make it
physically unable to send or delete anything.

Next: [Part 1, a first agent reading one inbox over MCP](01-first-agent-mcp.md).
