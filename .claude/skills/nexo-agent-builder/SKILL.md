---
name: nexo-agent-builder
description: Build AI agents, tools, and workflows using Nexo (the nexo_ai gem, Ruby namespace Nexo), the opinionated Ruby agent harness built on ruby_llm. Use this skill whenever the user asks to create, extend, or debug a Nexo::Agent, a Nexo::Workflow, a custom tool for a Nexo agent, MCP wiring, sandbox/permissions configuration, or anything involving the nexo_ai gem — even if they just say "add an agent" or "build a workflow" in a project that already depends on nexo_ai. Also use when reviewing Nexo-based code for correctness (naming, safe defaults, composition rules).
---

# Nexo Agent Builder

Nexo is a Ruby agent harness: `Agent = Model + Harness`. It composes the
`ruby_llm` ecosystem (`ruby_llm`, `ruby_llm-skills`, `ruby_llm-mcp`,
`ruby_llm-schema`) into one front door with two genuinely new pieces — a
**Sandbox + Permissions** seam and a **WorkflowRun** durability primitive.
Everything else is composed, not reimplemented.

**Vocabulary this skill uses on purpose.** Nexo's own maintainers talk about
the codebase using a handful of fixed phrases — reuse the exact same words in
your own reasoning and code comments rather than paraphrasing them, so a
review or a commit message reads as consistent with how the project already
describes itself: **compose, don't reimplement** · **provider-neutral** ·
**safe by default, explicit escalation** · **verify, don't guess**.

## Configure ruby_llm before any of this runs

Nexo has no credential system of its own — `RubyLLM.configure` handles every
provider's API key, and it is a **separate call** from `Nexo.configure`
(which only sets Nexo's own defaults: `default_model`, `default_sandbox`,
`default_permissions`). Both typically live in their own initializer, side
by side.

```ruby
# config/initializers/ruby_llm.rb (Rails), or just called before use in plain Ruby
RubyLLM.configure do |config|
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  config.ollama_api_base   = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434/v1")
end
```

`NEXO_MODEL` only names *which* model to use — it does nothing to
authenticate. An agent with a correctly-set `model` but no matching
`RubyLLM.configure` credential raises from inside `ruby_llm` itself at
request time, not from Nexo, and not at agent-construction time.

## Before writing anything: the one naming rule

The published gem is `nexo_ai` (RubyGems name only — `nexo` was taken). The
Ruby namespace is **always `Nexo`**, never `NexoAi`, anywhere: no class,
module, constant, error message, or doc reference uses `NexoAi`. If you see
`NexoAi` in code you're touching, it's a bug — fix it to `Nexo`.

```ruby
gem "nexo_ai"        # Gemfile / gemspec — the ONLY place "nexo_ai" appears
require "nexo"        # NOT require "nexo_ai" in application code
class MyAgent < Nexo::Agent  # NOT Nexo::AI:: or NexoAi::
```

## Quick reference: the six things you build

```ruby
# 1. An Agent — a model + sandbox + permissions + instructions + skills
class CodeReviewer < Nexo::Agent
  model       ENV.fetch("NEXO_MODEL")   # never a hardcoded vendor default
  sandbox     :local                    # :virtual (default) | :local | :docker | :apple
  permissions :read_only                # :read_only (default) | :auto | :ask | :approve
  instructions "You are a careful code reviewer."
end
CodeReviewer.new(cwd: "/path/to/repo").prompt("Review the auth module")

# 2. A Workflow — a finite job with a persisted run (status/result/event log)
class SummarizeDocument < Nexo::Workflow
  def call(payload)
    emit(:started, doc_id: payload[:doc_id])
    { summary: payload[:text].slice(0, 280) }
  end
end
run = SummarizeDocument.run(doc_id: 1, text: "...")
run.status   # => "done"
run.result   # => { "summary" => "..." }

# 3. A custom Tool — a plain RubyLLM::Tool, attached by overriding #chat
class LookupOrder < RubyLLM::Tool
  description "Look up an order by id"
  param :order_id, type: :string, required: true
  def execute(order_id:)
    order = Order.find_by(id: order_id)
    order ? order.attributes : { error: "order #{order_id} not found" }
  end
end

class SupportAgent < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  def chat(base: nil) = super.with_tools(LookupOrder.new)
end

# 4. An MCP server — declared, not hand-wired
class InboxDigest < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  mcp :gmail, transport: :stdio, command: "npx", args: %w[-y srv-gmail]
end
```

```markdown
# 5. A Skill — reasoning guidance, not a tool. app/skills/triage/SKILL.md:
---
name: triage
description: Triage incoming issues by severity and route them to the right owner.
---

# Triage

## Process
1. Classify the issue severity.
2. Route to the right owner.
```

```ruby
class TriageAgent < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  skills :triage   # one macro, no loader wiring — instructions layer on top of `instructions`
end
```

```ruby
# 6. Structured output — ruby_llm-schema directly against agent.chat.
# No Nexo macro exists (or is needed) — ruby_llm >= 1.16 hard-depends on
# ruby_llm-schema, so it's always present, never a MissingDependencyError risk.
class PersonSchema < RubyLLM::Schema
  string  :name, description: "Person's full name"
  integer :age
end

reviewer = CodeReviewer.new(cwd: "/path/to/repo")
response = reviewer.chat.with_schema(PersonSchema).ask("Generate a person named Alice, age 30")
response.content   # => {"name" => "Alice", "age" => 30} — already-parsed Hash
```

## Human-in-the-loop approval

`:approve` permission mode plus `Workflow#run_agent` gives *durable* approval —
not a blocking prompt. The run suspends and persists; a host renders a
pending-approval UI straight from `run.state`; the workflow resumes exactly
where it paused once a human decides, even across a process restart.

```ruby
class Fixer < Nexo::Agent
  model       ENV.fetch("NEXO_MODEL")
  sandbox     :local
  permissions :approve   # a sensitive capability with no decision yet raises
end                       # Nexo::ApprovalRequired instead of running

class ApplyPatch < Nexo::Workflow
  agent Fixer
  def call(_payload)
    run_agent("Fix the bug and write the patch")
    # run_agent rescues ApprovalRequired for you and calls #suspend! —
    # you never write that rescue yourself
  end
end

run = ApplyPatch.run
run.status                  # => "suspended"
run.state["__approval__"]   # => {"capability"=>"write", "tool"=>"...", "args"=>{...}}

ApplyPatch.resume(run.id, approved: true)   # or resume_later — the decision
                                             # threads into the same gate
```

A standalone `Agent` (no `Workflow` driving it) under `:approve` mode just
raises `Nexo::ApprovalRequired` for you to rescue yourself — the durable
suspend/resume only happens through `Workflow#run_agent`. Never rescue
`ApprovalRequired` inside your own tool code; it's meant to propagate.

## Rails generators — run these before writing code

Plain Ruby needs none of this — `Nexo::RunStore::Memory` works with zero
setup. In a Rails app, run the relevant generator *first*, since it scaffolds
the layout and persistence the rest of this skill assumes:

| Command | Creates | Run it |
|---|---|---|
| `rails g nexo:install` | `app/agents/`, `app/workflows/`, `app/skills/` (+ `.keep`), `config/initializers/nexo.rb` | Once, the first time Nexo is added to the app |
| `rails g nexo:workflows` | Migration for `nexo_workflow_runs` — id, status, payload, result, events, **and already includes `artifacts` + `state`** | Before using `Nexo::Workflow` with persisted (ActiveRecord) runs instead of the in-memory store |
| `rails g nexo:skill NAME` | `app/skills/NAME/SKILL.md` + `references/` | Scaffolding a new `ruby_llm-skills` package to attach via `skills :name` |

Run `rails db:migrate` after `nexo:workflows`.

## Decision framework: which one do I reach for?

| Need | Reach for | Not |
|------|-----------|-----|
| A model that reads/writes files, runs shell, calls tools in one turn-based conversation | `Nexo::Agent` | a bare `RubyLLM::Chat` — you lose the sandbox/permissions seam |
| A background job with a persisted status/result you can poll or resume | `Nexo::Workflow` | a plain `ActiveJob` — you lose the run record, event log, checkpoint/resume |
| One extra domain-specific capability (DB lookup, internal API call) | A plain `RubyLLM::Tool`, attached via `Agent#chat` override | a new Nexo primitive — Nexo has no `tools` macro; this is intentional composition |
| Reusable domain guidance/playbooks the model should consult conditionally | A `ruby_llm-skills` `SKILL.md` package (`app/skills/`), declared via `skills :name` | baking it into `instructions` — that costs tokens on *every* prompt |
| Calling an external service that already speaks MCP | `mcp` macro | a hand-rolled HTTP client tool |
| Getting back parsed JSON/a Hash instead of free text | `agent.chat.with_schema(MySchema).ask(...)` (`ruby_llm-schema`, always present — hard dep of `ruby_llm` itself) | inventing a Nexo `schema` macro — there is none, and none is needed |
| A step that needs to pause for human approval or an external event, then continue | `Workflow#checkpoint` + `#suspend!` + `::resume` | a loop that polls, or a tool that blocks |
| Several independent expensive steps in one workflow | `Workflow#checkpoint_all` | hand-rolled threads/futures |
| Running an agent from a background job | `Workflow.run_later` (needs ActiveJob) + `agent` macro on the workflow + `#run_agent` | calling `Agent#prompt` directly inside a raw `ActiveJob` — you lose the run record |

## Core principles (non-negotiable — flag violations, don't just fix them)

### 1. Compose, don't reimplement
If you're about to hand-write a tool-call loop, a skill loader, an MCP
client, or a JSON-schema-to-tool converter — stop. That's `ruby_llm` core,
`ruby_llm-skills`, `ruby_llm-mcp`, or `ruby_llm-schema`'s job. Nexo only adds
the Sandbox/Permissions seam, the WorkflowRun lifecycle, and DSL glue.

### 2. Provider-neutral, always
```ruby
# ✅ GOOD
model ENV.fetch("NEXO_MODEL")

# ❌ BAD — hardcodes a vendor
model "claude-sonnet-4-5"
```
No `Nexo.config.default_model` ships with a value. Anthropic-specific paths
(`Loops::AgentSDK`) are opt-in only, never the default `loop:`.

**The `assume_model_exists` catch.** `ruby_llm` validates every model id
against its bundled `models.json` registry and infers the provider from it.
A local Ollama tag (`gemma3:12b`), a self-hosted build, or a model newer than
the installed registry isn't in there — so it needs two macros together, not
one:

```ruby
# ✅ GOOD — provider declared alongside assume_model_exists
class LocalReviewer < Nexo::Agent
  model               "gemma3:12b"
  provider            :ollama         # required once the registry lookup is skipped
  assume_model_exists true            # opt out of models.json validation
  instructions "You are a careful code reviewer."
end

# ❌ BAD — raises Nexo::ConfigurationError at instantiation:
# "assume_model_exists is set but no provider given"
class LocalReviewer < Nexo::Agent
  model               "gemma3:12b"
  assume_model_exists true            # provider missing — ruby_llm can't infer one
end
```

`assume_model_exists` defaults to `false` (registry validation stays on).
Reach for it only when a model genuinely isn't in the registry yet — local
Ollama tags, self-hosted builds, brand-new releases. Try without it first:
the registry lookup is a real typo-catcher on normal hosted model ids, and
setting the flag skips that check along with the intended one.

### 3. Safe by default — escalation must be visible in user code
```ruby
# Default: :virtual sandbox (in-memory, zero host access), :read_only permissions
class Reviewer < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  # no sandbox/permissions line = safest possible agent
end

# Escalating requires an explicit, visible line — never silently assumed
class Fixer < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  sandbox     :local     # explicit opt-in to real filesystem
  permissions :auto      # explicit opt-in to read/write/shell/fetch/search
end
```
Every escalation from the safe defaults appears as its own explicit macro
line, visible in a diff and reviewable on its own — that visibility is the
entire point of the safe-by-default design, not an incidental style choice.

### 4. Tool failures return `{ error: ... }`, never raise
```ruby
# ✅ GOOD — model can see the error and adapt
def execute(path:)
  @sandbox.read(path)
rescue Errno::ENOENT => e
  { error: e.message }
end

# ❌ BAD — crashes the whole tool loop
def execute(path:)
  @sandbox.read(path)  # raises, kills the conversation
end
```
This applies to *your* custom tools too, not just Nexo's built-ins.
`Nexo::ApprovalRequired` is the one deliberate exception — it's a
control-flow signal for `:approve` permission mode, not a tool failure, and
it's meant to propagate.

### 5. Verify, don't guess
Before asserting a `ruby_llm`/`ruby_llm-mcp`/ActiveJob API detail (a method
name, a callback signature, a `.set` keyword), check it against the
*installed* gem — never hardcode a version number in code or comments.
```sh
bundle exec ruby -e 'require "ruby_llm"; puts RubyLLM::VERSION'
bundle show ruby_llm  # then read the actual source
```

## Common pitfalls

| Pitfall | Why it's wrong | Fix |
|---|---|---|
| `NexoAi::Agent` | The namespace is always `Nexo` | `Nexo::Agent` |
| Setting `NEXO_MODEL` and expecting an agent to just work | It only names the model — `ruby_llm` still needs its own `RubyLLM.configure` credential for that provider | Add `RubyLLM.configure` alongside `Nexo.configure`; they're separate calls |
| `assume_model_exists true` with no `provider` macro | Raises `Nexo::ConfigurationError` — `ruby_llm` can't infer a provider once the registry lookup is skipped | Always pair it with `provider :ollama` (or whichever) |
| Setting `assume_model_exists true` on a normal, already-registered hosted model | Silently skips a real validation (e.g. would have caught a typo'd model id) for no benefit | Only set it for local Ollama tags, self-hosted builds, or models newer than the installed registry |
| Adding a `tools` macro to an `Agent` subclass | Nexo has no such macro — the four sandbox tools are wired internally | Override `#chat` and call `super.with_tools(YourTool.new)` |
| Rescuing `Nexo::ApprovalRequired` inside your own tool code | It's a control-flow signal meant to propagate, not a tool failure | Let it propagate; `Workflow#run_agent` already rescues it into a durable suspend |
| Looking for a `schema` macro on `Nexo::Agent`, or guarding structured output behind a dependency check | No macro exists (or is needed); `ruby_llm-schema` is a hard dependency of `ruby_llm` itself, not a soft one like `ruby_llm-skills`/`ruby_llm-mcp` | Call `agent.chat.with_schema(MySchema).ask(...)` directly — never `MissingDependencyError` risk |
| Calling `Agent#prompt` inside a bare `ActiveJob` for background work | You lose the run record, status, event log | Use `Nexo::Workflow` + `run_agent` + `run_later` |
| A workflow with no `sandbox`/`agent` declared calling `#stage`/`#artifact`/`run_agent` | These need a resolved sandbox — raises `ConfigurationError` | Declare `sandbox :local` (or `:docker`) and, for `run_agent`, an `agent MyAgent` line |
| Calling `#suspend!` inside a `checkpoint` block | Undefined behavior — v1 unsupported | Call `#suspend!` outside any checkpoint |
| Naming a checkpoint `__suspend__`, `__approval__`, or `__buffer_events__` | Reserved state keys | Pick a domain name |
| Assuming `skills :name` widens what an agent can do | A skill contributes **instructions only** — Nexo deliberately doesn't attach `ruby_llm-skills`' own progressive-disclosure tool (ungated `File.read`) | The model reaches a skill's `references/`/`scripts/` only through the agent's own sandbox-gated tools — attaching a skill never changes the effective sandbox/permission mode |
| Assuming `run_later`/`resume_later` retries automatically on crash | Nexo adds no `retry_on` by design (host's ActiveJob owns retries) | Configure `retry_on` on your own job, or call `reconcile_interrupted!` at boot |
| A tool that raises instead of returning `{ error: }` | Kills the tool loop instead of letting the model adapt | Rescue and return `{ error: msg }` |
| Escalating `permissions :auto` "just for this one example" | Silently defeats safe-by-default | Keep `:read_only` unless the task genuinely needs write/shell/fetch |

## Testing conventions

- Minitest. **The core suite runs offline** — no API keys, no live model, no
  Ollama required.
- Stub the model layer with `ruby_llm-test`; use `sandbox :virtual` for
  deterministic tool tests (no real filesystem).
- A workflow test needs no Rails/DB — `Nexo::RunStore::Memory` backs it in
  plain Ruby. Reset with `Nexo::RunStore::Memory.reset!` in `setup`.
- Test outcomes (`run.status`, `run.state["x"]`, `run.result`), not
  implementation details.
- Live-model smoke tests are `NEXO_LIVE=1`-gated only — never a dependency of
  the core suite.

```ruby
class MyWorkflowTest < Minitest::Test
  def setup = Nexo::RunStore::Memory.reset!

  def test_completes_with_expected_result
    run = MyWorkflow.run(id: 1)
    assert_equal "done", run.status
    assert_equal "expected", run.result["key"]
  end
end
```

## When you need more depth

This skill covers the common patterns and the rules that must never be
broken. For full detail, read the installed gem's own docs (shipped with
`nexo_ai`, find the gem path with `bundle show nexo_ai`), or the canonical
source repo: **https://github.com/maquina-app/nexo**

> The repo may still be private — a fetch returning 403/404 means "not public
> yet," not "this doesn't exist." Don't report the project as missing or
> made up on a failed fetch; fall back to the installed gem's local `docs/`
> and note that the repo link couldn't be reached this time.

Docs to reach for by topic (paths relative to the repo/gem root):

| Topic | File |
|---|---|
| Sandboxes (Virtual/Local/Remote/Container) | `docs/sandboxes.md` |
| Permissions modes and the `:ask`/`:approve` gates | `docs/permissions.md` |
| Built-in tools (ReadFile/WriteFile/Shell/Glob) | `docs/tools.md` |
| Loop backends (RubyLLM vs AgentSDK) | `docs/loops.md` |
| Workflow lifecycle, staging, artifacts | `docs/workflows.md` |
| Checkpoint/suspend/resume durability | `docs/durable-workflows.md` |
| SKILL.md packages for agents | `docs/skills.md` |
| MCP wiring | `docs/mcp.md` |
| Fetch/WebSearch tools | `docs/web.md` |
| Sessions (continuing a chat) | `docs/sessions.md` |
| Rails integration (`run_later`, broadcasting, generators) | `docs/rails.md` |
| Opt-in async concurrency | `docs/concurrency.md` |
| Docker/Apple container sandboxes for scripted data pipelines, persisting transient files across steps and runs | `references/docker-data-pipelines.md` (bundled with this skill) |

If a doc file referenced above doesn't exist in the installed gem version,
say so rather than inventing its contents — the gem is under active
development and doc coverage may lag newer features.
