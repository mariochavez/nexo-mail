# Blog series: "Building an email agent with Nexo"

A step-by-step series that teaches **Nexo** (the `nexo_ai` gem) by building
`nexo_mail`: a read-only AI email-triage tool that reads Apple Mail, Gmail & HEY
and produces a briefing (`digest.json` + a self-contained `dashboard.html`).

**The arc.** We start where Nexo's own `examples/inbox_digest.rb` starts: a
five-line agent reading one inbox, and grow it, one Nexo feature per post, into
a multi-inbox, skill-driven, workflow-orchestrated, dashboard-producing library.
Every post ends with working code you can run against a local model (Ollama).

**Spine of the story:** *Agent = Model + Harness.* Each post adds one piece of
the harness and shows the Nexo feature that provides it.

---

## The posts

### 0 · Agent = Model + Harness: meet Nexo
- **Nexo features:** the thesis (compose, don't reimplement); the two things Nexo adds (Sandbox+Permissions seam, WorkflowRun); the five-line agent; provider-neutrality; safe defaults (`:virtual` + `:read_only`); `assume_model_exists`/`provider` for local models.
- **Build:** project intro + `Nexo.configure`; run a first throwaway agent on a local Ollama model.
- **Takeaway:** the model reasons; the harness is everything else, and Nexo gives you the harness with safe defaults.

### 1 · Your first real agent: reading one inbox over MCP
- **Nexo features:** Agent class macros; the `mcp` macro (stdio transport); `permissions :read_only` + `mcp_allow` (fail-closed allow-list); the four built-in tools.
- **Build:** `AppleMailSource`: read Apple Mail via `apple-mail-mcp`, write a digest fragment. Read-only *by construction* (send/delete are denied even though the server exposes them).
- **Takeaway:** point an agent at a service in a few lines; the allow-list is the safety boundary.

### 2 · Skills: teaching the model *how*, not *what*
- **Nexo features:** the `skills` macro; `SKILL.md` packages; "a skill contributes instructions only"; `references/`/`scripts/` stay sandbox-gated; the skills path / seeding pattern.
- **Build:** the `email_triage` skill; move the classification rules out of Ruby into Markdown; make the deliverable a structured JSON contract.
- **Takeaway:** change behavior by editing Markdown, not code, and why that matters for small local models.

### 3 · More inboxes, more tool shapes: IMAP and CLI as tools
- **Nexo features:** custom `RubyLLM::Tool`s attached via a `#chat` override; the sandbox/permission seam still applies; provider-neutrality (IMAP, not a Gmail SDK); the `inherited`/`CONFIG_IVARS` copy behavior; instance-level readers so one agent serves many sources.
- **Build:** Gmail (IMAP `EXAMINE`) and HEY (CLI wrappers; `HeyBox`'s three boxes) as tools. One base agent + a *data-driven* `EmailSource` reading a `Sources` descriptor per service; Apple Mail keeps its own class for the class-level `mcp` macro.
- **Takeaway:** every service converges to "a tool the agent can call" — and a tool-based source is data (a descriptor), not a class.

### 4 · Workflows: turning agents into a finite job
- **Nexo features:** `Nexo::Workflow`; `run` → runId / status / result / inspectable **event log**; workflow ≠ agent; forwarding agent events.
- **Build:** `MultiInboxTriage`: walk the `Sources` catalog, run each source agent, record outcomes, stay bulletproof (skip unavailable sources, degrade failures). The CLI's per-source `✓/✗/⊘` report comes from the event log.
- **Takeaway:** a workflow is the *job* (status, log, result); agents are the *skilled loops* inside it.

### 5 · Fan-out: concurrency without hand-rolled threads
- **Nexo features:** `Nexo.concurrent`, `max_in_flight`, `:threaded` vs `:async` (opt-in fiber offload).
- **Build:** run the three sources concurrently so their LLM round-trips overlap; fall back to sequential when `async` isn't installed.
- **Takeaway:** bounded fan-out in one call: no thread pools, no futures.

### 6 · The safety model: read-only by construction
- **Nexo features:** the four sandbox tiers (`:virtual`/`:local`/`:docker`/`:apple`); the `Local` escape guards (`../` + symlink); permission modes (`:read_only`/`:auto`/`:ask`/`:approve`); `mcp_allow` / `fetch_allow`; when `Shell` attaches.
- **Build:** the fenced `:local` workspace sandbox; the three read-only mail patterns side by side; granting only `:write` beyond read-only.
- **Takeaway:** safety is a property of the harness, not a promise in a prompt.

### 7 · Composing a pipeline: synthesis & the "thin Ruby" rule
- **Nexo features:** several agents in one workflow; structured output options (write-to-sandbox vs `ruby_llm-schema`); the orchestration-only philosophy.
- **Build:** the `Synthesize` agent → `digest.json` + `inbox-digest.md`; cross-source & cross-group dedup, money roll-up, stories, radar. "Ruby = tools + orchestration; agents + skills do the work."
- **Takeaway:** keep the library thin; push judgment into agents and skills.

### 8 · Skills that ship assets: a template + a script the agent runs
- **Nexo features:** skills bundling `scripts/`/`assets/`; the `Shell` tool; opening a permission *narrowly* (the scoped `:shell` exception); config-driven asset paths; the `artifact(from:)` template idea.
- **Build:** the `dashboard_designer` skill (a fixed template + `render_dashboard.rb`); the `Publisher` runs it via shell to produce a byte-identical, XSS-safe `dashboard.html`. The security tradeoff and its mitigations.
- **Takeaway:** when you must open the sandbox, open it for one agent, for one job, and say why.

### 9 · Durable & human-in-the-loop: checkpoints, suspend/resume, approval
- **Nexo features:** `checkpoint`/`suspend!`/`resume`; `:approve` mode + `Nexo::ApprovalRequired`; `Workflow#run_agent`; durable approval that survives a restart.
- **Build:** the (optional) next step: a human-approved action (e.g. "draft a reply" or a destructive prune) gated behind `:approve`; how a read-only tool grows a safe write path.
- **Takeaway:** the WorkflowRun primitive lets an agent pause for a human and resume exactly where it stopped.

### 10 · Shipping it: CLI, config, packaging & Rails
- **Nexo features:** sessions (continuing a chat); loop backends (RubyLLM vs AgentSDK); Rails integration (generators, `run_later`, broadcasting, scheduling).
- **Build:** the `nexo-triage` CLI, the XDG/TOML config layer, gem packaging, snapshots + `--prune-snapshots`; then move the same workflow into a Rails app or a cron.
- **Takeaway:** the same agents/workflow run from a CLI, a job, or a web request unchanged.

---

## Voice and style (match the author's blog)
- **No em dashes.** Use periods, colons, parentheses, or commas instead.
- **No marketing, no vibe, no punchy openers.** Helpful and technically correct.
  Cut repeated thematic sentences and rhetorical framing.
- **First person, decision-journey tone.** Open with a concrete problem or goal,
  then the technical how, explained plainly. Honest about trade-offs and limits.
- **Plain, direct headings** ("How the allow-list enforces read-only access",
  "What will trip you up"), never clever wordplay.
- **Prose around code:** say why before the code block, then explain usage after.
- **Close pragmatically** (what this changed / what to watch), not a hype summary.

## Structural conventions for every post
- **Runnable on a local model** (Ollama `gemma3:12b` or similar), no vendor lock-in.
- **One feature, one milestone:** each post adds a real capability to `nexo_mail`.
- **A "What will trip you up" section** at the end, in prose, with the real
  gotchas from building this (not a decorated callout box).
- **Diagrams** reuse the `docs/architecture.html` visual language where useful.

## Optional shapes
- **Short series (6):** merge 0+1, 4+5, 9+10 → a tighter "zero to shipped" arc.
- **Deep series (11):** as above, one post each.
- **Companion repo tags:** tag the example repo per post so readers can `git checkout post-04`.
