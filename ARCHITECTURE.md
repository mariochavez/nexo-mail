# Architecture

How Nexo Mail Agent is put together, bottom to top.

## Core idea

Two ideas carry the whole design.

**1. Agent = model + harness.** Every "agent" is a model doing the reasoning plus
a harness ([`nexo_ai`](https://rubygems.org/gems/nexo_ai) on
[`ruby_llm`](https://github.com/crmne/ruby_llm)) supplying everything else — the
tools it can call, the skills that teach it *how*, the permission gate that keeps
it read-only, the fenced sandbox it writes into, and the loop that runs
"model → tool → model" until done.

**2. Ruby is only tools + orchestration; agents and skills do the work.** The
library provides read-only mail tools and a thin workflow that decides *which*
agents run and *in what order*. Everything else — extracting each inbox,
de-duplicating, rolling up the money, writing the digest, rendering the
dashboard, archiving snapshots — happens on the **agent + skill** side. The one
sanctioned exception is a bounded, correctness-critical primitive exposed as a
*tool the agent calls* (snapshot pruning; the dashboard render script).

The run produces two deliverables — **`digest.json`** (canonical data) and a
self-contained **`dashboard.html`** — plus `inbox-digest.md` for the terminal,
all archived to a timestamped snapshot.

## Layers

```
┌──────────────────────────────────────────────────────────────────────┐
│  ENTRY POINT     exe/nexo-triage → NexoMail::CLI                       │
│    run a triage · --check · --prune-snapshots · --help                 │
└──────────────────────────────────────────────────────────────────────┘
                                  │
┌──────────────────────────────────────────────────────────────────────┐
│  ORCHESTRATION   MultiInboxTriage < Nexo::Workflow  (thin)             │
│    decides which sources run, sequences the agents, forwards events    │
│    — reads no mail, parses no JSON, renders nothing                    │
└──────────────────────────────────────────────────────────────────────┘
                                  │
┌──────────────────────────────────────────────────────────────────────┐
│  AGENTS  (Nexo::Agent)                                                  │
│    SourceAgent (base: model · :local sandbox · :read_only+write)       │
│      ├─ EmailSource (Gmail·HEY, from a Sources descriptor)             │
│      └─ AppleMailSource (MCP)              → extract                   │
│    Synthesize  → digest.json + inbox-digest.md                         │
│    Publisher   → dashboard.html   (+ :shell, to run the render script)  │
│    Archivist   → snapshot + prune (via tools)                          │
└──────────────────────────────────────────────────────────────────────┘
                                  │
┌──────────────────────────────────────────────────────────────────────┐
│  SKILLS  (data/skills/*, seeded to the XDG skills dir)                  │
│    email_triage · financial_summary · interest_radar   (extraction)    │
│    inbox_synthesis      (build the digest)                             │
│    dashboard_designer   (template + render script for the dashboard)   │
│    snapshot_keeper      (archive / prune policy)                       │
└──────────────────────────────────────────────────────────────────────┘
                                  │
┌──────────────────────────────────────────────────────────────────────┐
│  INTEGRATION — one pattern per service, all → "callable tools"         │
│    MCP macro          IMAP tools            CLI-wrapper tools           │
│    apple-mail-mcp     GmailImap::List/Read  HeyBox / HeyThread          │
│    (stdio subprocess) (net-imap, EXAMINE)   (Open3, hardcoded argv)     │
│    + snapshot tools:  ArchiveRun · PruneSnapshots                       │
└──────────────────────────────────────────────────────────────────────┘
                                  │
┌──────────────────────────────────────────────────────────────────────┐
│  MODEL           ruby_llm, any provider (ollama/openai/…)              │
│    the active [[models]] entry from config.toml (--model / first)      │
└──────────────────────────────────────────────────────────────────────┘
```

## The pipeline — four stages

```
   ┌── AppleMailSource (MCP) ──┐
   ├── EmailSource · Gmail ────┤   1. EXTRACT (parallel)   → apple-mail.json
   └── EmailSource · HEY ──────┘      each writes a JSON      gmail.json · hey.json
                                     array of items
                    │
              Synthesize          2. BUILD THE DIGEST   → digest.json
                                    merge · dedupe ·       + inbox-digest.md
                                    money roll-up ·
                                    stories · people ·
                                    topic briefings
                    │
              Publisher           3. RENDER             → dashboard.html
                                    runs the skill's
                                    template+script (shell)
                    │
              Archivist           4. ARCHIVE            → snapshots/<ts>/
                                    snapshot + prune       (via tools)
```

Each stage is one agent (stage 1 fans out to three). The workflow runs them in
order, forwarding every tool call/result into the run's event log.

### What a run leaves behind

Files in the workspace are not the deliverable — they are where the deliverable
happens to land. Each agent **declares** its output, and the workflow copies those
bytes onto the run record itself:

```ruby
class Synthesize < SourceAgent
  produces "digest.json", "inbox-digest.md"
end

class Publisher < SourceAgent
  produces "dashboard.html"
end
```

After every stage — including the paths where the stage *failed*, because an agent
that died after writing its file still produced it — the workflow calls
`collect_artifacts(agent)`, which resolves each declared name through the run's
sandbox and stores it. `run.artifacts` then carries the deliverables independently of
the directory they were written to, which is what makes the pipeline portable to an
ephemeral sandbox and what a caller embedding this workflow as a library gets back
without having to know where on disk we wrote anything.

Declared, never swept: a sweep of the workspace would also collect the staged render
script, the template and every scratch file, and an agent naming its outputs is the
only honest way to say *"this run produced nothing."*

The source agents are the one case that cannot use `produces` — a single
`EmailSource` **class** serves every tool-based inbox, and the filename comes from the
per-instance descriptor — so the workflow records those by path instead
(`artifact(file, path: file)`, the same verbatim, no-ERB copy `produces` uses
underneath). Neither is ever fatal: an artifact that could not be recorded emits
`artifact_skipped` and the run continues.

### What a stage needs, and saying so before it starts

The Publisher cannot work without a Ruby interpreter, so it says so:

```ruby
requires commands: {"ruby" => ">= 3.0"}
```

Nexo probes the agent's **own sandbox** once, before the first turn, and raises
`Nexo::EnvironmentError` naming every unmet requirement at once. That matters here
because the sandbox shell runs with a narrowed `PATH` (`PATH`/`HOME`/`LANG` only), so
the environment the render command runs in is not the one your terminal has.
Provisioning it is the operator's job — pin `[dashboard] ruby` to an absolute
interpreter when yours is version-managed — and this declaration just turns a
mid-run `ruby: command not found` into a preflight failure with a legible sentence.
`nexo-triage --check` runs the same probe and prints what the sandbox actually has.

The skill states the same need in prose, through the Agent Skills spec's own field:

```yaml
compatibility: Needs a Ruby 3.0+ interpreter reachable from the sandbox shell…
```

Two audiences, two mechanisms: `requires` is checked and fails the run; the skill's
`compatibility:` is appended to the model's instructions so it knows what it is
working with and can say so plainly instead of improvising HTML.

## The integration patterns

Each service exposes itself differently, so each is reached differently — but all
converge to the same abstraction the agent sees: **a tool it can call.**

| Service | Pattern | Where | Read-only because… |
|---------|---------|-------|--------------------|
| Apple Mail | **MCP** | `mcp :mail` in `AppleMailSource` | Nexo's MCP gate is fail-closed; only `MAIL_READ_TOOLS` allowed |
| Gmail | **IMAP tools** | `tools/gmail_imap/{list,read}.rb` | mailbox opened with `EXAMINE`; `BODY.PEEK` sets no flags |
| HEY | **CLI-wrapper tools** | `tools/hey_box.rb`, `hey_thread.rb` | argv arrays (no shell) to hardcoded read subcommands |

Gmail and HEY are **tool-based** sources: they share **one** `EmailSource` agent
that reads its tools + prompt key from a `NexoMail::Sources` **descriptor**, so
adding another IMAP/CLI-style service is a descriptor, not a class. `SourceAgent`
attaches the descriptor's tools in `#chat` (`super`, then `with_tools(...)`).
Apple Mail keeps its own `AppleMailSource` because the `mcp` macro is class-level
and can't be expressed per-instance.

**HEY has four boxes**, and `HeyBox` takes a `boxes` ARRAY so one call returns them
all: **Imbox** (people → action/fyi), **The Feed** (newsletters → tag topics),
**Paper Trail** (receipts → extract payments), **Set Aside** (parked mail → fyi).
The canonical names the model uses (`imbox`, `feed`, `papertrail`, `setaside`) are
translated by `Tools::Hey::BOXES` into what the CLI actually wants (`imbox`,
`feedbox`, `trailbox`, `asidebox` — the `kind` field, not the label); an unknown
name is an explicit error rather than a silent fallback.

**Reads are batched.** `GmailImap::Read` takes `uids: []` and `HeyThread` takes
`thread_ids: []`, so a body read costs one model round trip instead of N — and for
Gmail one IMAP session instead of N, since `with_inbox` opens a fresh connection per
call. Both listings now carry a plain-text `snippet` (Gmail via a grouped partial
IMAP fetch + MIME decoding, HEY from the `summary` the API already returns), so most
messages are classified without any body read at all. `Tools::Pool` provides the
bounded fan-out inside a single tool call.

**Concurrency is fibers end to end.** The workflow already fans its source agents out
with `Nexo.concurrent` (async); `Tools::Pool` uses `Sync` + `Async::Semaphore`/
`Barrier` rather than OS threads; and `Config.tool_concurrency` defaults to `:fibers`
so ruby_llm overlaps multiple tool calls from a single assistant turn on that same
reactor. This is sound because Async's scheduler hooks `process_wait`/`io_read`/
`io_wait`, so `Open3.capture3` and `Net::IMAP` yield instead of blocking — four
`sleep 0.4` subprocesses go 1.64s → 0.41s, and four IMAP connects 0.95s → 0.17s.

The one resource that cannot take concurrency is the `hey` CLI, which races on the
macOS keyring. `Tools::Hey.run` holds a process-wide fiber-aware `Mutex` around every
invocation, so the race is impossible regardless of which caller reaches it — that
lock, not a tuning knob, is what makes the rest of the concurrency safe.

Apple Mail is the exception: `apple-mail-mcp` is a third-party server whose
`get_email` is one-message-at-a-time and untruncated. `AppleMailSource` wraps its
gated MCP tools in `Tools::CappedTool` to bound the reply, and the `email_triage`
skill steers the agent toward `search` (batched, with `content_snippet`) instead of
repeated `get_email`.

## Where judgment lives

Ruby does I/O and exact arithmetic; every judgment is a skill. Concretely:

| Question | Answered by |
|---|---|
| What day is it? | `Tools::Today` — a clock, no opinions |
| How far back does the briefing reach? | the **skills** (15th of previous month → today), passed to tools as `since:` |
| Which payments belong in the totals? | the **skills** — the tool adds up whatever it is given |
| What is 100.00 + 80.00 + 949.00? | `Tools::SumPayments` — BigDecimal, per currency, never converting |
| Which mail is action / fyi / noise? | the **skills** |
| How much mail may one call return? | Ruby (`hey_box_limit`, `gmail_list_limit`) — volume, not relevance |

The two deterministic tools exist because both were measurably wrong in the model:
dates (a schedule of appointments already two months past) and money (`by_currency`
disagreeing with its own `charges` list). Both are the `PruneSnapshots` carve-out —
bounded, agent-invoked, and neither parses model output nor writes an artifact.

## The skills — where the intelligence lives

Skills are `SKILL.md` packages (instructions only) that teach the model *how*.
Changing behavior means editing Markdown, not Ruby.

| Skill | Attached to | Does |
|-------|-------------|------|
| `email_triage` | source agents | classify → JSON items; entity extraction contract |
| `financial_summary` | source + synthesize | identify payments/charges; Briq & Yo Te Presto always-financial; transaction dedup |
| `interest_radar` | source + synthesize | tag & brief newsletter topics (Ruby, Rails, Photography, Tech) as bullets |
| `inbox_synthesis` | synthesize | merge, cross-source & cross-group dedup, money roll-up, stories, people |
| `dashboard_designer` | publisher | the dashboard: a fixed template + a render script (run, don't hand-write) |
| `snapshot_keeper` | archivist | when to archive / how many to keep |

## The dashboard — a skill-owned template, rendered deterministically

The dashboard's design and rendering live **with the skill**, not in the library:

- `dashboard_designer/assets/dashboard-template.html` — the fixed design (CSS + a
  JS renderer that builds the page from an embedded `digest.json` blob).
- `dashboard_designer/scripts/render_dashboard.rb` — injects the run's
  `digest.json` into the template, escaping the untrusted email text so it can't
  break out of the `<script>`. Deterministic; never trusts the model.

The Publisher pulls both from **config-driven paths** (`[dashboard]` in
`config.toml` — `template`/`renderer`/`ruby`, defaulting to the skill assets) and
runs the render in one shell call. So every run is **byte-identical** and
XSS-safe, and restyling means editing the template — never the app's Ruby.

## Safety model (cross-cutting)

- **Read-only mail, three ways:** MCP fail-closed gate, IMAP `EXAMINE`, hardcoded
  read subcommands with no general shell.
- **Fenced writes.** Every agent runs a `:local` sandbox rooted at the workspace;
  the path guard rejects `../` traversal and symlink escapes. Beyond read-only,
  agents get only `:write` (`SANDBOX_WRITE = %i[read glob write]`).
- **One scoped shell exception.** The **Publisher alone** also gets `:shell`, purely
  to run the render script — it attaches no mail tools and reads only the
  already-produced `digest.json`. Every mail-reading agent stays `:read_only` with
  no shell (`AppleMailSource.permissions.authorize!(:shell)` raises; the Publisher's
  does not).
- **Bounded destructive tools.** `PruneSnapshots` deletes only inside the snapshots
  dir; the agent decides *to* prune, the tool does the deletion deterministically.
- **De-dup, twice.** Cross-source (the same email in two inboxes) and cross-group
  (one message shows in only its strongest surface), both handled in synthesis.

### Opening the read-only guarantee — deliberately and narrowly

The dashboard is a skill-owned template rendered by a *script*, and running a
script needs a shell. Nexo attaches its `Shell` tool only when the sandbox
supports `:shell` (Local does) **and** permissions allow it — a read-only agent
has neither. So exactly one capability was added to exactly one agent.

**What was opened** — one line, one agent (mode stays `:read_only`):

```ruby
SourceAgent (all mail agents)  Permissions.new(mode: :read_only, allow: %i[read glob write])
Publisher only                 Permissions.new(mode: :read_only, allow: %i[read glob write shell])
```

**Why it stays safe:**

- The Publisher attaches **no mail tools** — it can't reach any inbox; it reads
  only the already-produced `digest.json`.
- The script it runs is **developer-authored and bundled** with the skill (pulled
  from config-driven paths), never model-generated.
- The shell runs inside the `:local` sandbox with a **narrowed ENV**
  (`PATH`/`HOME`/`LANG` only).
- The XSS escaping happens **in the script** (code), not trusted to the model.
- The workflow hands the **exact command**; the Publisher just runs it.

**Alternatives considered, and why not:**

- *A Ruby render tool / ERB in the library* — rejected: keeps artifact generation
  in the app, against "Ruby = tools + orchestration only."
- *Orchestration runs the script* (no shell) — the safest option, but the decision
  was for the agent to execute it through the skill.
- *Embed the scaffold in skill text* (model re-emits ~300 lines) — no shell, but
  not byte-identical and unreliable on small models.

**Blast radius, stated plainly:** an LLM now holds a sandboxed shell, scoped to an
agent with no mail access, reading only derived data, running a fixed script.
Every inbox-touching agent stays strictly read-only — verify with
`AppleMailSource.permissions.authorize!(:shell)` (raises) vs the Publisher's (does not).

## Why this shape

- **Ruby stays thin.** Tools + orchestration only, so behavior is tuned by editing
  skills, and the app never parses model output or renders HTML. The accepted
  trade: money arithmetic runs in the model (a `compute_totals` tool could make it
  deterministic if needed).
- **One agent per stage/source** keeps each context small and lets a flaky source
  fail in isolation. Sources fan out **concurrently** via `Nexo.concurrent` (opt-in
  `async`), falling back to sequential.
- **Workflow ≠ agent.** The workflow is the *finite job* (runId, status, event log);
  agents are the *skilled loops*. The same workflow can run from a CLI, cron, or a
  web request unchanged.
- **A template for the dashboard**, not model-authored HTML, because a daily
  briefing must look the same every run. The skill still owns it.

## File map

| Layer | File |
|-------|------|
| Entry point | `exe/nexo-triage` → `NexoMail::CLI` (`lib/nexo_mail/cli.rb`) |
| Orchestration | `lib/nexo_mail/workflows/multi_inbox_triage.rb` |
| Source catalog | `lib/nexo_mail/sources.rb` (`Sources.all` — one descriptor per service) |
| Agents | `lib/nexo_mail/agents/*.rb` (`source_agent` base, `email_source`, `apple_mail_source`, `synthesize`, `publisher`, `archivist`) |
| Skills | `data/skills/*/SKILL.md` (+ `dashboard_designer/{assets,scripts}`), seeded to XDG |
| Integration — Gmail (IMAP) | `lib/nexo_mail/tools/gmail_imap.rb` + `gmail_imap/` |
| Integration — HEY (CLI) | `lib/nexo_mail/tools/hey_box.rb`, `hey_thread.rb`, `cli_reader.rb` |
| Integration — Apple Mail (MCP) | `mcp :mail` in `lib/nexo_mail/agents/apple_mail_source.rb` |
| Snapshots | `lib/nexo_mail/snapshots.rb` + `tools/{archive_run,prune_snapshots}.rb` |
| Config / boot | `lib/nexo_mail/{config,bootstrap,theme}.rb`, `lib/nexo_mail.rb` (Zeitwerk) |

## Config layer (XDG)

Everything runtime-configurable comes from `NexoMail::Config`, reading
`$XDG_CONFIG_HOME/nexo-mail/config.toml` (created on first run by
`NexoMail::Bootstrap`). Precedence is **`NEXO_MAIL_*` env > config.toml >
default**, and any string supports `${VAR}` interpolation. It supplies the
model(s) (no default — first unless `--model`), service credentials, theme
flavor, the sandbox/skills/prompts/snapshots dirs, snapshot retention, and the
`[dashboard]` template/renderer/ruby. Only one model runs per invocation, so the
CLI configures `ruby_llm` globally from the selected model.
