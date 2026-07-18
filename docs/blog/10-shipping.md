---
title: "Shipping it: a CLI, a gem, and a Rails job"
date: 2026-07-17
category: desarrollo
tags: [ruby, ai, nexo, rails, packaging]
series: "Building an email agent with Nexo"
part: 10
---

# Shipping it: a CLI, a gem, and a Rails job

The tool works, but it has been a script I run by hand with environment variables
in front of it. This last post turns it into something installable: a `nexo-triage`
command, a configuration layer, a gem, and, because the same workflow can run
anywhere, a sketch of the same thing inside a Rails app. The theme of the post is
that almost none of this touches the agents or the workflow. They were already the
reusable part.

## The command

The CLI is thin. It parses options, provisions config on first run, points
`ruby_llm` at the selected model, runs the workflow, and prints the result. The core
of it:

```ruby
def run(argv)
  Bootstrap.ensure!            # first run: write default config, seed skills
  opts = parse(argv)           # OptionParser

  return print_check           if opts[:check]
  return prune_snapshots(opts[:prune]) if opts.key?(:prune)

  configure_model!(opts[:model])
  triage
end
```

`--check` runs a preflight that reports which model and which services are ready,
without triaging anything, which is the first thing you want when something is not
configured. `--prune-snapshots` runs the archivist to trim old runs.
`--help` documents the config. The default, with no flags, runs a triage and prints
the digest and the paths to the JSON and the dashboard.

The run itself reads the workflow's event log to show per-source progress, exactly
the log from Part 4. The UI is a consumer of the run record, not a separate source
of truth.

## One model per run makes configuration simple

There is a small design decision in `configure_model!` worth pulling out. A single
invocation runs exactly one model. Because of that, the CLI configures `ruby_llm`
globally from the selected model rather than threading a per-chat context
everywhere:

```ruby
def configure_model!(cli_alias)
  model = Config.active_model(cli_alias)   # --model, else NEXO_MAIL_MODEL, else first
  RubyLLM.configure do |c|
    c.public_send("#{model.provider}_api_base=", model.api_base) unless model.api_base.to_s.empty?
    c.public_send("#{model.provider}_api_key=",  model.api_key)  unless model.api_key.to_s.empty?
  end
  Nexo.config.default_model = model.model
  Agents::SourceAgent.configure_model!(model)  # set provider/model on every agent class
end
```

`configure_model!` on the base agent walks every triage class and sets the model and
provider on each, so the inheritance-copy timing from earlier posts is a non-issue:
by the time any agent is instantiated, every class already has the right model. If a
future version needed two models in one run, this is the spot that would grow a
`ruby_llm` context; for one model, global configuration is the simpler correct
choice.

## Configuration from XDG and TOML

All runtime configuration comes from one place, a `Config` module that reads a TOML
file under the XDG config directory, created on first run. The precedence is
consistent everywhere: an environment variable wins, then the file, then a built-in
default, and any string value can interpolate an environment variable with
`${VAR}`.

```toml
[[models]]
alias    = "local"
provider = "ollama"
model    = "gemma3:12b"
api_base = "http://localhost:11434/v1"

[services.gmail]
address      = "${GMAIL_ADDRESS}"
app_password = "${GMAIL_APP_PASSWORD}"

[dashboard]
ruby = "/path/to/ruby"
```

The rule I followed is that no agent or tool ever reads an environment variable or
hardcodes a path directly. They ask `Config`. That keeps every setting documented in
one example file and overridable by an environment variable of a known name, which
matters a lot once other people run the tool.

## Packaging the gem

Two things about packaging are specific to a tool built this way.

The first is that the skills, prompts, and the dashboard assets are data, and the
gemspec has to ship them. If `data/**` is not in the packaged files, the tool
installs and then fails at runtime because the skills are not there. It is an easy
line to forget and a confusing failure to debug, so it is worth a test that the
built gem actually contains them.

The second is the seeding from [Part 2](02-skills.md). On first run the tool copies
its bundled skills into the user's config directory only if they are absent, so the
packaged copies are defaults and the user's copies are overrides. The consequence
carries into upgrades: editing a packaged skill in a new gem version does not reach a
user who already has a copy, so an upgrade that changes a skill has to sync it into
the config directory.

Everything else is ordinary gem structure: one class per file, autoloaded, with no
top-level constants leaking, which you can verify by requiring the gem and checking
that a bare constant name resolves to nothing.

## The same workflow in Rails

Here is the part that pays off the whole design. Moving this into a web app does not
rewrite the agents or the workflow. It changes how the workflow is invoked and how
its events are surfaced.

Nexo ships a Rails engine and generators. `rails g nexo:install` creates the
layout, and `rails g nexo:workflows` creates the migration for the run table, so
runs persist in your database instead of in memory. A controller then starts a run
in the background:

```ruby
run = MultiInboxTriage.run_later(account_id: current_user.account_id)
redirect_to run_path(run.id)
```

`run_later` enqueues on your existing ActiveJob adapter and returns immediately. The
job carries only the run id, not the payload, so nothing sensitive travels through
the queue; the payload lives on the run record. The show page then streams the run's
events live. Nexo emits `ActiveSupport::Notifications` for every event and status
change, and with Turbo enabled it will append them to a per-run stream, so the same
`emit` calls that print check marks in the terminal render as a live progress list
in the browser. When the run finishes, you hand back the artifact:

```ruby
send_data run.artifact_content("dashboard.html"), type: "text/html"
```

The agents did not change. The workflow did not change. The CLI reads the event log
to print a summary; the web app reads the same event log to stream a page. That is
what the workflow primitive was for.

There is one more shape worth naming, since the tool is currently fire-and-finish. If
you wanted a conversational inbox assistant instead, one that remembers across days
that you always treat a certain sender as Noise, Nexo has sessions for that: an
addressable agent instance that accumulates context across separate invocations and
processes. It is the remembering counterpart to the finishing workflow, and it is
how you would turn a daily digest into an ongoing assistant.

## A note on the loop

One knob I have not mentioned drives everything under the hood: the loop that runs
model, tool, model to completion. Nexo ships two and lets you swap them by
injection. The default runs on any `ruby_llm` model, which is what let this whole
series run on a local model. A second, Anthropic-oriented loop is available when you
want its native turn cap and built-in tools. You would change the loop without
touching an agent class. It is not something you reach for early, but it is why the
provider-neutral default never boxed us in.

## What we built, and what it leaned on

Over these posts the tool grew from a five-line agent into a real thing: it reads
three inboxes through three integrations, each read-only for a concrete reason,
triages them with skills you edit as Markdown, runs the sources concurrently,
synthesizes one digest, renders a consistent dashboard through a skill that ships its
own script, and runs from a command line or a Rails app unchanged.

Underneath, it kept leaning on the same two things Nexo adds. The sandbox and
permission seams are what made read-only an enforced property and let one agent get
a narrowly scoped shell without weakening the rest. The workflow lifecycle is what
turned a pile of agents into a job with a status, a result, and an event log that
the CLI and a web app both read. Everything else, the skills, the tool loop, MCP,
the structured output, came from the `ruby_llm` gems Nexo composes rather than
rebuilds. That was the bet the first post described, and building the whole tool is
the argument for it.

## What will trip you up

`run_later` needs a shared store. Enqueuing to a real background adapter requires the
ActiveRecord run store; the in-memory store only works inline.

There is no automatic retry or crash recovery. A crashed or retried job re-runs
`#call` from the top. Configure `retry_on` in your host job if you want retries, and
run the interrupted-run sweep at boot so a run killed mid-flight does not sit in a
running state forever.

Ship your data files. Put `data/**` in the gemspec's files, and test that the built
gem contains the skills and assets, or the tool installs and fails at runtime.

Sessions store conversation history, which is a data-retention surface. Nexo does not
expire or redact it. If you add a conversational assistant, own that retention.

That is the series. The tool is small, but it exercised most of Nexo, and each piece
arrived when the tool actually needed it, which is the only way I know to learn a
library that you will keep.
