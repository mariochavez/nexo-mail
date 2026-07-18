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
│      ├─ AppleMailSource   ├─ GmailSource   ├─ HeySource   → extract     │
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
   ┌── AppleMailSource ──┐
   ├── GmailSource ──────┤   1. EXTRACT (parallel)   → apple-mail.json
   └── HeySource ────────┘      each writes a JSON      gmail.json · hey.json
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

## The integration patterns

Each service exposes itself differently, so each is reached differently — but all
converge to the same abstraction the agent sees: **a tool it can call.**

| Service | Pattern | Where | Read-only because… |
|---------|---------|-------|--------------------|
| Apple Mail | **MCP** | `mcp :mail` in `AppleMailSource` | Nexo's MCP gate is fail-closed; only `MAIL_READ_TOOLS` allowed |
| Gmail | **IMAP tools** | `tools/gmail_imap/{list,read}.rb` | mailbox opened with `EXAMINE`; `BODY.PEEK` sets no flags |
| HEY | **CLI-wrapper tools** | `tools/hey_box.rb`, `hey_thread.rb` | argv arrays (no shell) to hardcoded read subcommands |

`GmailSource`/`HeySource` attach their tools by overriding `Nexo::Agent#chat`
(`super`, then `with_tools(...)`). `AppleMailSource` uses the `mcp` macro instead.

**HEY has three boxes**, and `HeyBox` takes a `box` param so the agent pulls all
three: **Imbox** (people → action/fyi), **The Feed** (newsletters → tag topics),
**Paper Trail** (receipts → extract payments).

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
  no shell (`GmailSource.permissions.authorize!(:shell)` raises; the Publisher's
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
`GmailSource.permissions.authorize!(:shell)` (raises) vs the Publisher's (does not).

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
| Agents | `lib/nexo_mail/agents/*.rb` (source ×3, `synthesize`, `publisher`, `archivist`) |
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
