# Architecture

How `mail-agent` is put together, bottom to top.

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
│  ENTRY POINT        triage.rb                                     │
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
│  KNOWLEDGE          skills/email_triage/SKILL.md                 │
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
│  MODEL              ruby_llm → Ollama (OpenAI-compatible /v1)     │
│    glm-5.2:cloud    (LLM_API_BASE / LLM_API_KEY / LLM_MODEL)      │
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
| Gmail | **IMAP tools** | `lib/gmail_imap.rb` (`List`, `Read`) | mailbox opened with `EXAMINE`; `BODY.PEEK` doesn't set flags |
| HEY | **CLI-wrapper tools** | `lib/cli_sources.rb` (`HeyImbox`, `HeyThread`) | argv arrays (no shell) to hardcoded read subcommands |

`GmailSource`/`HeySource` attach their tools by overriding `Nexo::Agent#chat`
(calling `super`, then `with_tools(...)`). `AppleMailSource` uses the `mcp` macro
instead, so it needs no override.

## How a run flows (`triage.rb`)

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
   across sources, applies the VIP rules, and **writes** `./sandbox/inbox-digest.md`.
5. The workflow reads that file back and records it as an **artifact**; `triage.rb`
   prints it.

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
| Entry point | `triage.rb` |
| Orchestration + agents | `lib/multi_inbox.rb` |
| Knowledge | `skills/email_triage/SKILL.md` |
| Integration — Gmail (IMAP) | `lib/gmail_imap.rb` |
| Integration — HEY / gws (CLI) | `lib/cli_sources.rb` |
| Integration — Apple Mail (MCP) | `mcp :mail` macro in `lib/multi_inbox.rb` |
| Model/shared config | `lib/config.rb` |
