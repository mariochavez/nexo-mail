# Architecture

How Nexo Mail Agent is put together, bottom to top.

## Core idea

Every "agent" here is **a model + a harness**. The model (`glm-5.2:cloud`) does the
reasoning; the harness ([`nexo_ai`](https://rubygems.org/gems/nexo_ai), built on
[`ruby_llm`](https://github.com/crmne/ruby_llm)) supplies everything else — the
tools it can call, the skill that teaches it *how* to triage, the permission gate
that keeps it read-only, the fenced sandbox it writes into, and the loop that runs
"model → tool → model" until a final answer. The model alone is stateless; the
harness is the rest.

## Layers

```
┌─────────────────────────────────────────────────────────────────┐
│  ENTRY POINT        exe/nexo-triage                               │
│    runs the workflow, streams the event log, prints the digest   │
└─────────────────────────────────────────────────────────────────┘
                                │
┌─────────────────────────────────────────────────────────────────┐
│  ORCHESTRATION      MultiInboxTriage < Nexo::Workflow            │
│    per source: run its agent (writes a fragment to ./sandbox)    │
│    → run the merge agent → record inbox-digest.md as an artifact │
└─────────────────────────────────────────────────────────────────┘
                                │
┌─────────────────────────────────────────────────────────────────┐
│  AGENTS  (Nexo::Agent)                                            │
│    SourceAgent (shared base: model, :read_only+write, :local,   │
│                 email_triage skill)                              │
│      ├─ AppleMailSource   ├─ GmailSource   ├─ HeySource          │
│    MergeDigests  < SourceAgent  (no mail tools; merges fragments)│
└─────────────────────────────────────────────────────────────────┘
                                │
┌─────────────────────────────────────────────────────────────────┐
│  KNOWLEDGE          skills/email_triage/SKILL.md (XDG, seeded)   │
│    buckets (Action/FYI/Noise), digest template, VIP senders,    │
│    injected into every agent as system prompt                   │
└─────────────────────────────────────────────────────────────────┘
                                │
┌─────────────────────────────────────────────────────────────────┐
│  INTEGRATION  — one pattern per service, all → "callable tools"  │
│    MCP macro         IMAP tools           CLI-wrapper tools      │
│    apple-mail-mcp    GmailImap::List/Read Hey* (argv → hey)      │
│    (stdio subprocess)(net-imap, EXAMINE)  (Open3, hardcoded cmd) │
└─────────────────────────────────────────────────────────────────┘
                                │
┌─────────────────────────────────────────────────────────────────┐
│  MODEL              ruby_llm, any provider (ollama/openai/…)      │
│    the active [[models]] entry from config.toml (--model / first) │
└─────────────────────────────────────────────────────────────────┘
```

## The three integration patterns

Each service exposes itself differently, so each is reached differently — but they
all converge to the same abstraction the agent sees: **a tool it can call.** That
convergence is why adding a fourth service is just "pick a pattern, write a source
agent."

| Service | Pattern | Where | Read-only because… |
|---------|---------|-------|--------------------|
| Apple Mail | **MCP** | `mcp :mail` macro in `AppleMailSource` | Nexo's MCP gate is fail-closed; only `MAIL_READ_TOOLS` are allowed |
| Gmail | **IMAP tools** | `lib/nexo_mail/tools/gmail_imap/` (`List`, `Read`) | mailbox opened with `EXAMINE`; `BODY.PEEK` doesn't set flags |
| HEY | **CLI-wrapper tools** | `lib/nexo_mail/tools/hey_imbox.rb`, `hey_thread.rb` | argv arrays (no shell) to hardcoded read subcommands |

`GmailSource`/`HeySource` attach their tools by overriding `Nexo::Agent#chat`
(calling `super`, then `with_tools(...)`). `AppleMailSource` uses the `mcp` macro
instead, so it needs no override.

## How a run flows (`exe/nexo-triage`)

1. `MultiInboxTriage.run` starts a **workflow** — it gets a `runId`, a status, and
   an event log — and `mkdir`s `./sandbox`.
2. For each entry in `SOURCES` (`name => [AgentClass, "fragment.md"]`) it
   instantiates the **source agent** rooted at `./sandbox` and prompts it. The agent
   loops: reads its inbox via its tools, classifies against the **skill**, and
   **writes its fragment** (`./sandbox/apple-mail.md`, `gmail.md`, `hey.md`). Every
   tool call/result is mirrored into the workflow event log via `forward_event`.
3. A source that raises is caught → its fragment becomes a visible "Triage failed"
   note; the other sources still run.
4. The fragments are handed to the **merge agent**, which pools "needs action"
   across sources, applies the VIP rules, and **writes** the digest. If the merge
   itself fails (e.g. the model is down), the run falls back to concatenating the
   per-source fragments so a digest is always produced — a merge failure never
   discards the source work.
5. The workflow reads that file back and records it as an **artifact**;
   `exe/nexo-triage` prints the per-source outcome summary (`✓`/`✗`/`⊘`) and the digest.

Sources are **preflight-checked** before step 2: one whose binary is missing or
whose credentials are absent is skipped (with a reason) and never enters the fan-out;
one that errors mid-run degrades to a "failed" note. The run always continues.

## Safety model (cross-cutting)

- **Read-only mail, three ways** (see the integration table above): MCP fail-closed
  gate, IMAP `EXAMINE`, and hardcoded read subcommands with no general shell.
- **Fenced writes.** Every agent runs a `:local` sandbox rooted at `./sandbox`; the
  path guard rejects `../` traversal and symlink escapes, so writes can't leave that
  directory. The single capability granted beyond the read-only defaults is
  `:write` (`SANDBOX_WRITE` = `%i[read glob write]`) — never `:shell`.
- **Least privilege.** All agents run under Nexo's `:read_only` mode; Apple Mail
  additionally carries the exact-match `mcp_allow` list and nothing more.

## Why this shape

- **One agent per service** keeps each context small and focused (one inbox, one
  tool set) and lets a flaky source fail in isolation. The three sources are fanned
  out **concurrently** via `Nexo.concurrent` (opt-in `async` gem) so their LLM
  round-trips overlap; results come back in source order and the merge runs after.
  Falls back to sequential if `async` isn't installed.
- **Workflow ≠ agent.** The workflow is the *finite job* (runId, status, event log,
  artifact); the agents are the *skilled loops*. Nexo separates these so the same
  workflow can run from a CLI, a cron job, or a web request unchanged.
- **Skill-as-policy.** All "how to triage" logic lives in one small Markdown file,
  so changing buckets, the digest format, or VIP senders never touches Ruby.

## File map

| Layer | File |
|-------|------|
| Entry point | `exe/nexo-triage` → `NexoMail::CLI` (`lib/nexo_mail/cli.rb`) |
| Orchestration | `lib/nexo_mail/workflows/multi_inbox_triage.rb` |
| Agents | `lib/nexo_mail/agents/*.rb` |
| Knowledge | bundled `data/skills/email_triage/SKILL.md`, seeded to the XDG skills dir |
| Integration — Gmail (IMAP) | `lib/nexo_mail/tools/gmail_imap.rb` + `gmail_imap/` |
| Integration — HEY / gws (CLI) | `lib/nexo_mail/tools/hey_*.rb`, `gws_*.rb`, `cli_reader.rb` |
| Integration — Apple Mail (MCP) | `mcp :mail` macro in `lib/nexo_mail/agents/apple_mail_source.rb` |
| Config / boot | `lib/nexo_mail/{config,bootstrap,theme}.rb`, `lib/nexo_mail.rb` (Zeitwerk) |

## Config layer (XDG)

Everything runtime-configurable comes from `NexoMail::Config`, which reads a TOML
file at `$XDG_CONFIG_HOME/nexo-mail/config.toml` (created on first run by
`NexoMail::Bootstrap`). Precedence is **`NEXO_MAIL_*` env > config.toml > default**,
and any string value supports `${VAR}` interpolation. The config supplies the
model(s) (no default — first used unless `--model`), service credentials, the theme
flavor, the sandbox/skills/prompts dirs, and per-agent prompt fragments. Because
only one model runs per invocation, the CLI configures `ruby_llm` globally from the
selected model rather than per-chat contexts.
