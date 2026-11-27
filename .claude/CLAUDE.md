# nexo_mail — project guide for agents

Read-only AI email triage, packaged as a Ruby gem. It reads Apple Mail, Gmail, and
HEY, and produces a briefing: **`digest.json`** (canonical data) + a self-contained
**`dashboard.html`** ("The Desk", Catppuccin Mocha), plus `inbox-digest.md` for the
terminal. Built on `nexo_ai` (agent harness) + `ruby_llm`. Executable: `nexo-triage`.

**Architecture rule (load-bearing — the owner is emphatic):** the Ruby side is
**tools + orchestration only**. Every artifact (extraction, digest, dashboard,
snapshots) is produced by an **agent driven by a skill** writing into the sandbox.
Do NOT add Ruby that parses model output, rolls up numbers, renders HTML, or
formats a digest — express that as a `data/skills/*/SKILL.md` and let an agent do
it. The lone exception: a bounded, correctness-critical primitive may be a thin
Ruby **tool** the agent *calls* (e.g. `PruneSnapshots` deletes dirs
deterministically; the agent decides *to* call it). Money arithmetic USED to run in the
model; it was measurably wrong, so it now runs in `Tools::MoneyReport`, which the
agent calls — the carve-out, not an exception to it.

## Commands

```sh
bundle install
exe/nexo-triage --check              # preflight: model + services readiness
exe/nexo-triage --help               # config + per-service setup docs
exe/nexo-triage                      # run a triage (needs a model + services)
exe/nexo-triage --prune-snapshots 20 # agent-driven prune, keep newest 20
exe/nexo-triage --reset-ledger       # forget what was triaged; next run is a full read
exe/nexo-triage --reset-ledger money # forget one lane only; that mail is triaged again
exe/nexo-triage --rebuild-digest     # next run builds the digest in full (no mail re-read)
RUBYLLM_WIRE=1 exe/nexo-triage       # show raw ruby_llm/MCP logs
gem build nexo_mail.gemspec           # package (data/** must be included)
bundle exec standardrb lib            # lint (Standard); --fix to autofix
```

The exe self-boots Bundler from a source checkout, so no `bundle exec` prefix is
needed. Test against a throwaway config so you never touch a real `~/.config`:

```sh
XDG_CONFIG_HOME=$(mktemp -d) XDG_STATE_HOME=$(mktemp -d) exe/nexo-triage --check
```

## Layout

```
lib/nexo_mail.rb            # boot: requires, Zeitwerk loader, NexoMail:: constants
lib/nexo_mail/
  config.rb                 # NexoMail::Config — XDG/TOML, ${VAR}, ENV precedence
  bootstrap.rb              # first-run provisioning (idempotent, copy-if-missing)
  theme.rb                  # Catppuccin palettes (lipgloss) + Glamour styles
  cli.rb                    # NexoMail::CLI — the runner (OptionParser + UI, thin)
  snapshots.rb              # NexoMail::Snapshots — create/list/prune (used by tools)
  ledger.rb                 # NexoMail::Ledger — what each inbox already triaged (used by tools)
  sender_memory.rb          # NexoMail::SenderMemory — sender → lane (reader's rules + learned tally)
  digest_file.rb            # NexoMail::DigestFile — full/update/current plan + key-level commit
  sources.rb                # NexoMail::Sources — the source catalog (descriptors)
  agents/                   # SourceAgent base + EmailSource (data-driven, tool-based
                            #   Gmail/HEY) + AppleMailSource (MCP), Synthesize (digest),
                            #   Publisher (dashboard), Archivist
  tools/                    # CliReader, Hey/HeyBox/HeyThread, McpWrapper (CappedTool, UnseenOnly),
                            #   Today, MoneyReport (deterministic primitives),
                            #   GmailImap(::List/::Read/::Mime/::BodyPart),
                            #   ArchiveRun, PruneSnapshots, CommitExtraction (ledger merge),
                            #   UnseenOnly (ledger filter around an MCP listing),
                            #   NewItems (items no digest holds yet), CommitDigest
                            #   (replace digest keys / put+drop list entries)
  workflows/                # MultiInboxTriage < Nexo::Workflow (orchestration only)
data/                       # PACKAGED: config.example.toml, skills/, themes/, prompts/
  skills/                   # email_triage, financial_summary, interest_radar (extract),
                            #   inbox_synthesis (digest), dashboard_designer (HTML),
                            #   snapshot_keeper (archive/prune)
exe/nexo-triage             # 3-line shim → NexoMail::CLI.run(ARGV)
```

## Pipeline (agent + skills driven)

1. **Source agents** (AppleMail/Gmail/HEY, parallel) extract the mail that is NEW
   since the last run and commit it into a structured JSON array file
   (`gmail.json`, …) holding the whole window. Skills: `email_triage`,
   `financial_summary`, `interest_radar`. The workflow walks `NexoMail::Sources.all`
   — one **descriptor** per source (name, file, `prompt_key`, tools, availability).
   Tool-based sources (Gmail, HEY) share ONE `Agents::EmailSource` built from a
   descriptor; adding such a service is a descriptor, not a class. Apple Mail keeps
   its own `AppleMailSource` because its `mcp` macro is class-level.
2. **Synthesize** keeps `digest.json` + `inbox-digest.md` — a FULL build from those
   files, an UPDATE from only the items triaged since, or not run at all
   (`DigestFile.plan`):
   merge, **cross-source dedupe**, money rollups, schedule, stories, per-person
   detail, topic briefings. Skills: `inbox_synthesis`, `financial_summary`,
   `interest_radar`.
3. **Publisher** renders `dashboard.html` by RUNNING the `dashboard_designer`
   skill's bundled `scripts/render_dashboard.rb` over `assets/dashboard-template.html`
   + `digest.json` (the workflow STAGES the skill's `scripts/`+`assets/` into the
   sandbox first, so the agent's gated file tools can reach them). The design is
   a fixed, versioned template rendered deterministically — the model does NOT author
   HTML. Editing the look = editing the template, not the skill prose.
4. **Archivist** archives the run + prunes old snapshots via the `ArchiveRun` /
   `PruneSnapshots` tools. Skill: `snapshot_keeper`.

The workflow only decides which agents run and sequences them; it reads no mail,
parses no JSON, renders nothing.

## Conventions

- **Fully namespaced under `NexoMail::`**, one class per file, Zeitwerk-autoloaded
  (`Zeitwerk::Loader.for_gem`). No top-level constants may leak — verify with
  `ruby -e 'require "nexo_mail"; p defined?(SourceAgent)'` → should be nil.
  Non-default inflection: `cli.rb` → `CLI` (registered in `lib/nexo_mail.rb`).
- **All runtime config comes from `NexoMail::Config`** — never read `ENV`/hardcode in
  agents/tools. Precedence is **`NEXO_MAIL_*` env > `config.toml` > default**; any
  TOML string supports `${VAR}` / `${VAR:-fallback}`. New setting → add a `Config`
  accessor + a `NEXO_MAIL_*` name + a line in `data/config.example.toml`.
- **Models**: no default. `Config.active_model(cli_alias)` picks `--model`, else
  `NEXO_MAIL_MODEL`, else the first `[[models]]`. One model runs per invocation, so
  the CLI mutates `RubyLLM.configure` globally and sets `NexoMail.active_model`,
  which `Agents::Base` reads lazily (`model`, `provider`, `assume_model_exists` are
  reader overrides of Nexo's macros) — do NOT reach for `RubyLLM.context`.
- **Skills** load from the XDG skills dir (`Config.skills_dir`), seeded copy-if-missing
  from `data/skills/`. Editing the XDG copy is the override. `nexo`'s `skills_path`
  is a single dir with no built-in precedence — that's why we seed. New skill dir →
  bootstrap seeds it automatically (`data/skills/*`); no code change needed.
  **Seed-once gotcha:** bootstrap copies *only if absent*, so editing a packaged
  `data/skills/*/SKILL.md` does NOT reach an existing install — the user's stale
  `~/.config/nexo-mail/skills/<name>/SKILL.md` wins. When iterating on skills for a
  live user, `cp` the updated file over their `Config.skills_dir` copy (or delete it
  so bootstrap re-seeds). This is by design — editing the XDG copy IS the override.
- **Every agent inherits `Agents::Base`; only mail-reading ones inherit `SourceAgent`.**
  `Base` holds what all share (sandbox, permissions, the `today` tool, prompt
  fragments, the model). `SourceAgent < Base` adds the extraction skills and triage
  instructions. `Synthesize`/`Publisher`/`Archivist` inherit `Base` directly and
  declare their own `skills`. Do NOT make a downstream agent a `SourceAgent`: Nexo's
  `skills` macro only accumulates, so it would inherit the extraction skills (the old
  code worked around that by poking `@skills`).
- **Agents DECLARE their output with `produces`; the workflow records it** (nexo_ai
  >= 0.9). `Synthesize` produces `digest.json` + `inbox-digest.md`, `Publisher`
  produces `dashboard.html`, and `MultiInboxTriage` calls `collect_artifacts(agent)`
  in `drive_agent`'s **ensure** — so a stage that wrote its file and then failed still
  gets recorded. The source agents can't use `produces` (one `EmailSource` CLASS
  serves every descriptor, and the filename is per-instance), so the workflow records
  those with `artifact(file, path: file)` — the `path:` mode, a verbatim copy, NOT
  `from:` which is ERB and would execute model-written content. Both are wrapped so a
  failure emits `artifact_skipped` and never sinks the run. This is what puts the
  deliverables on `run.artifacts`, durable independently of the sandbox dir.
  **The workflow needs `sandbox :local` + a lazy `def self.cwd = Config.sandbox_dir`**
  for any of it to work — `Nexo::Workflow`'s sandbox defaults to `:virtual`, where the
  agents' files do not exist. `cwd` is a READER override, not the macro's setter,
  because Config isn't loaded until `CLI.run`.
- **`Publisher` declares `requires commands: {"ruby" => ">= 3.0"}`** (nexo_ai >= 0.9).
  Nexo probes the agent's own sandbox once before the first turn and raises
  `Nexo::EnvironmentError` — so a narrowed-PATH `ruby: command not found` becomes a
  legible failure instead of a wasted turn. Provisioning is the OPERATOR's job, not
  this app's: keep the declaration to plain command names, don't try to work around a
  missing interpreter, and let it fail. `--check` runs the same probe
  (`CLI#print_sandbox_check`) so the gap shows up before a run. `drive_agent` rescues
  `Nexo::EnvironmentError` separately and tags the event `unmet: true` — the fix is
  provisioning, not a retry.
- **Runs persist to disk, and that is the ONLY reason `--resume` exists.**
  `CLI#configure_model!` sets `Nexo.config.run_store = Nexo::RunStore::Disk.new(dir:
  Config.runs_dir)` (nexo_ai >= 0.10). Nexo's default store is in-memory and dies
  with the process, so checkpoints/suspend/artifacts would all be unreadable next
  invocation. The workflow runs stage 1 as `checkpoint_all(source name => lambda)`:
  each source is its OWN checkpoint, persisted as it finishes, so a resume re-reads
  only an inbox that never landed. It calls `suspend!` when synthesis wrote no
  `digest.json` — "suspended" is a NON-failure, and `--resume` re-enters `#call` from
  the top where the checkpoints short-circuit the inboxes. `suspend!` must be OUTSIDE
  a checkpoint. `extract_source` must NEVER raise: a raising step fails the run and
  stops the other sources. A failed source checkpoints as `nil` and is not retried.
  Each checkpoint stores that source's filename, not the mail — the files
  live in the workspace. `--resume` handles three statuses: `suspended` goes to
  `Workflow.resume`, `failed` and `interrupted` to `Workflow.retry` (nexo_ai 0.16),
  after `reconcile_interrupted!` has marked a run a dead process left `"running"`.
  The workflow still suspends deliberately on an uncommitted digest: a suspend
  prints a hint, a raise prints a backtrace. Ctrl-C is caught in `CLI#drive`
  (`#interrupted`) and is NOT `Workflow.cancel`: a cancelled run is final.
  `--resume` picks the newest run by ID (UUIDv7), never by file time — the sweep
  rewrites old run files. Nexo never prunes run documents
  (`CLI#trim_runs` keeps `Config.runs_keep`).
- **The Publisher's shell is fenced by CONFIG, and the workspace is always shared.**
  `Agents::Publisher.sandbox` is a lazy READER override over `[dashboard] sandbox`
  (local|confined|docker|apple). Every value is a `Sandboxes::Local` on the shared
  workspace; what differs is its `isolation:` — none, `:confined` (mxc), or a
  `Nexo::Sandboxes::ContainerRunner` (a hardened, network-less container PER COMMAND
  with only the workspace bound in, at its own host path). So no stage has a
  workspace of its own and nothing is copied in or out (the old `hand_over_inputs` /
  `import_artifacts` / `shares_workspace?` / `in_workspace` are gone).
  UNSET, the value is `confined` where `Config.confinement_available?` and `local`
  otherwise; an explicit `confined` that cannot run raises at render time.
  `readable:` comes from `Config.dashboard_readable`: the directory of an absolute
  `template`/`renderer` override, plus (confined only) the interpreter's install —
  Nexo's `:ruby` preset for the CLI's own Ruby (the default: `dashboard_ruby` is
  `RbConfig.ruby`), or `dashboard_ruby_prefix` for a pinned `[dashboard] ruby`.
  Without it ruby starts but cannot load its stdlib. `Config.dashboard_containerized?`
  is true ONLY for docker/apple and only decides `publisher_ruby` (the image's `ruby`
  vs the pinned host one). The sandbox dir must be shared with the container VM
  (the home directory is, on OrbStack/Docker Desktop). `hardening_gaps` is emitted.
- **A skill states its needs in `compatibility:`** — the Agent Skills spec's own
  frontmatter field, which nexo_ai >= 0.9 appends to the model's instructions.
  `dashboard_designer` uses it to say it needs a Ruby 3.0+ interpreter and the shell
  tool, and that there is no fallback. Subject to the SAME seed-once gotcha as the
  rest of the skill: editing `data/skills/*/SKILL.md` does not reach an existing
  install — `cp` it over `Config.skills_dir`.
- **A new agent class needs no entry anywhere** — but it must inherit `Agents::Base`,
  which is where the model, sandbox and permissions come from.
- **Host tools are declared with Nexo's `tools` macro (nexo_ai >= 0.14), never by
  calling `with_tools` in `#chat`.** `Base` declares `Tools::Today` for everyone;
  `Synthesize` adds `MoneyReport`; `EmailSource` adds a lambda reading its descriptor;
  `Archivist` declares `ArchiveRun`/`PruneSnapshots` with `capability: :write`, which
  wraps them in `Nexo::GatedTool` (allowed because the shared permissions grant
  `:write`). The mail-reading tools carry no capability — read-only by construction.
  `Nexo.config.strict_tools` is on by default (nexo_ai 0.16): a tool attached any other way is
  REFUSED ("did not run"), so a new tool that is not declared silently does nothing.
  The old `source_tools`/`common_tools` hooks are gone.
- **Per-agent prompt fragments**: `SourceAgent#chat` appends `common.md` +
  `<prompt_key>.md` from `Config.prompts_dir` when present. Each source defines
  `self.prompt_key`.
- **Read-only by construction**: MCP fail-closed allow-list (Apple Mail), IMAP
  `EXAMINE` (Gmail), hardcoded CLI read subcommands via argv arrays (HEY). Agents run
  a `:local` sandbox fenced to `Config.sandbox_dir` with only `:read` and `:write` (`:glob` is still in
  the allow list and asks for nothing since nexo_ai 0.16). The file tools are
  ruby_llm's: `read_file` (20,000 chars a page, a line past 2,000 is cut),
  `list_files`, `search_files`, `write_file`, `edit_file`; a write to an existing
  file needs a read of it first in the same chat.
  **One scoped exception:** the `Publisher` agent alone also gets `:shell`, purely to
  run the bundled dashboard render script — it reaches NO mail (no mail tools).
  **As of nexo_ai 0.11 the `allow:` list decides the SCHEMA, not just the gate.** Nexo
  no longer attaches a tool the permission mode can never authorize, so a mail agent's
  `%i[read glob write]` means the model never even SEES a shell tool — before 0.11 it
  was advertised, models tried it, and each attempt burned a full round trip (measured
  in a real run at ~58s per turn). Adding a capability to an `allow:` list now changes
  what the model is offered, which is the thing to check when a tool "disappears".
  Verify:
  `ruby -Ilib -e '…; p Agents::SourceAgent.new(cwd: Dir.pwd).chat.tools.keys'`
  → no `shell`; the same for `Agents::Publisher` → `shell` present.
- **Skill-bundled files are AUTO-RESOLVED, never path-joined.** `scripts/`,
  `assets/`, `references/` is the Agent Skills convention, and `Nexo::Skills.find`
  already returns a `Skill` exposing `#scripts`/`#assets`. `Config.skill_script` /
  `#skill_asset` wrap that; `dashboard_renderer`/`dashboard_template` take the SKILL
  as an argument and the workflow passes `Agents::Publisher.skills.first`. Nothing
  names a skill or a filename outside the agent's own `@skills`, so renaming either
  needs no code change — verified by renaming both the skill dir and its files.
  A new script-bearing skill needs NO Config accessor.
  **Nexo deliberately does not attach the gem's `SkillTool`** (it does ungated
  `File.read`), and `Sandboxes::Local` is SINGLE-ROOTED — every read and write is
  guarded against one `cwd` — so a skill's files are invisible to the gated tools
  while they live outside the sandbox.
- **The workflow STAGES skill resources into the sandbox** (`stage_skill_resources`),
  copying every `scripts/`+`assets/` file the skill ships and preserving that layout,
  so the render command is workspace-relative and the agent can list `scripts/`
  through its permission-gated tools. **Accepted tradeoff:** the Publisher holds
  `:write` AND `:shell`, so a staged script sits in space it could rewrite before
  executing — outside the sandbox it could not be touched at all. Mitigation: we
  re-stage (overwriting) on EVERY run immediately before the agent runs, so tampering
  cannot persist across runs; the residual window is a single turn. A `[dashboard]`
  override is used as an absolute path instead and is never staged.
- **The dashboard is a skill-owned template, not model-authored HTML.** The design +
  render live in `data/skills/dashboard_designer/{assets/dashboard-template.html,
  scripts/render_dashboard.rb}` (seeded to `skills_dir`). The Publisher pulls them
  from **config-driven paths** and renders via shell:
  `Config.dashboard_ruby "<Config.dashboard_renderer>" digest.json "<Config.dashboard_template>" dashboard.html`.
  All three come from `[dashboard]` in config.toml (`NEXO_MAIL_DASHBOARD_{RUBY,RENDERER,TEMPLATE}`),
  defaulting to the skill assets + `ruby`. **Pin `[dashboard] ruby` to an absolute
  interpreter** when Ruby is version-managed (mise/asdf/rbenv) — the sandbox shell has
  a narrowed PATH and bare `ruby` may not resolve. Deterministic + XSS-safe (the script
  escapes the JSON blob). To restyle, repoint `template` / edit the template — never
  the app's Ruby, never the skill prose.
- **HEY has FOUR boxes, and the CLI name is the `kind`, not the label.**
  `NexoMail::Tools::Hey::BOXES` maps what the model says → what `hey box` wants:
  `imbox`→`imbox` (people → action/fyi), `feed`→`feedbox` (newsletters → tag
  `topics`), `papertrail`→`trailbox` (receipts → extract `payment`),
  `setaside`→`asidebox` (parked mail → usually fyi). `HeyBox` takes a `boxes`
  ARRAY and returns all of them in one call. An unknown name is an explicit error
  — never a silent fallback to the Imbox, which is how The Feed and Paper Trail
  went untriaged. Box *ids* are per-account; only the `kind` strings are stable.
- **`hey thread read` (hey CLI 1.7+; it was `hey threads` before, which now fails as an unknown command) wants the TOPIC id, not the posting `id`.** The topic id lives
  only inside `posting["app_url"]` (`https://app.hey.com/topics/<TOPIC_ID>`) and is
  a different number; reading by posting id always 404s. `Hey.thread_id` parses it,
  the listing exposes it as `thread_id`, and a `kind: "bundle"` posting (app_url
  `/contacts/…`) has none — it simply cannot be read.
- **`hey` cannot be called concurrently — `Tools::Hey::LOCK` is the invariant.**
  It serializes on the macOS keyring, so parallel invocations race and every loser
  exits 3 with "not logged in" (measured: 1 in flight → 12/12 ok, 2 → 9/12,
  3 → 6/12, 4 → 3/12). EVERY `hey` invocation goes through `Tools::Hey.run`, which
  holds a process-wide `Mutex` for the whole subprocess — so no caller can race it:
  not two tool calls running together, not the `Sources`
  availability probe. With the lock in place the same 8-way fan-out is 8/8. Never
  shell out to `hey` directly; add it to `Hey.run`.
- **Concurrency here is fibers, not threads.** `Config.tool_concurrency` defaults to
  **`:fibers`**, so ruby_llm overlaps multiple tool calls from one turn on async —
  the same reactor `Nexo.concurrent` already runs the source agents in.
  There is no fan-out INSIDE a tool call any more (`Tools::Pool` was removed with
  nexo_ai 0.16): its only users were the two HEY tools, and `Hey::LOCK` serializes
  every `hey` call anyway. A batched HEY tool is a plain loop; `Hey.run` turns
  anything raised into `{error:}` so one dead thread id cannot sink a batch.
  `hey` runs through `Nexo::Sandboxes::Subprocess` with `Config.cli_timeout`, which
  kills a call that hangs instead of leaving the lock held.
  Ruby's `Mutex` is fiber-aware, so `Hey::LOCK` yields instead of deadlocking the
  reactor. `async` is a hard dep of nexo_mail but only a SOFT one of nexo_ai.
- **The read tools are BATCHED and return JSON STRINGS.** `GmailImap::Read` takes
  `uids: []`, `HeyThread` takes `thread_ids: []` — one model round trip instead of
  N, and for Gmail one IMAP session instead of N. Both listings carry a `snippet`
  so most messages never need a body read at all. Every tool returns
  `JSON.generate(...)`. (ruby_llm 2.x now serializes a Hash result as JSON itself; under
  1.16 it reached the model as Ruby `inspect`. The explicit JSON keeps the shape ours.)
- **The run window is the AGENT's, not Ruby's.** Ruby holds no date policy at all:
  `Tools::Today` is a clock (today, month bounds, previous_month — no judgments),
  and the `email_triage` / `inbox_synthesis` skills define the window as *the 15th
  of `previous_month` → today* and pass it to the tools as `HeyBox(since:)` /
  `GmailImap::List(since:)`. Ruby bounds VOLUME only (`hey_box_limit`,
  `gmail_list_limit`); relevance is a judgment and lives in the skills. Omitting
  `since` means no date filter — deliberately, so the policy has exactly one home.
- **The model does NOT know the date, and it showed.** A run generated 2026-08-20
  published a schedule of 2026-06-18 / 2026-07-17 / 2026-07-23 — every appointment
  already past — and reported 2023 receipts as June charges. The fix is the `Today`
  tool plus a skill rule to call it FIRST; there is no date injected into prompts.
- **Money arithmetic is a TOOL now, not the model** — this reverses the old
  "accepted tradeoff". `Tools::MoneyReport` (attached to `Synthesize`) reads every
  `payment` on the ledgers itself — the model passes a PERIOD, never the payments,
  and never copies the result: the finished `finance` section is staged
  (`DigestFile.stage`) and saved by `commit_digest`, winning over any `finance` the
  model wrote anyway. Its predecessor `SumPayments` summed whatever the model
  re-typed into its arguments: right arithmetic over an unreliable transcription.
  BigDecimal, grouped per currency, NEVER converting. Directions are `paid`,
  `charged`, `due` (out) and `income`, `refund` (in) — `income` exists because a
  pay run was being filed as a refund. It makes no judgments: the period is
  the caller's, an unrecognised direction comes back in `needs_direction` uncounted,
  and only a row IDENTICAL to another (merchant, amount, currency, direction, date)
  is counted once on its own. The two real judgments arrive as arguments and are
  remembered in `ledger/money.json`: `settled: [{bill, payment}]` (that bill stops
  counting as due) and `skip: [ids]` (same transaction, different wording). It also
  returns `open_bills` (unpaid, amount or not — a bill whose notice shows no figure
  is `amount: null`, listed, never summed; `overdue` is date order against `until`),
  `previous` (an earlier period's totals) and `recurring_missing` (merchants with
  outflow in 2+ earlier calendar months and none in the period — set arithmetic;
  whether one is actually late is the skill's call). Money is read by CALENDAR
  MONTH, with the HEY Paper Trail listed back 90 days (`days_ago 90`) so there is a
  previous month to compare. `--reset-ledger money` re-triages just that lane
  (`Ledger#forget_lane`). Each currency is a self-contained block holding its own `charges` list
  AND the totals of that list, so the two cannot drift — they did: a run reported USD
  `charged: 289.00` against its own list summing to 269.00 (true figure 1218.00), and
  MXN `refund: 7,979.84` against 7,899.98 with `count: 5` for four entries.
- **Never merge currencies.** There is no FX rate anywhere in this project. The
  dashboard template used to sum `charged`/`due`/`paid` ACROSS currencies and label
  the result with the dominant one; it now renders one block per currency. Money is
  separated by currency in `MoneyReport`, in `digest.json`'s `finance.by_currency`,
  in the dashboard, and in `inbox-digest.md`.
- **Read shaping is config, and it is the only real bound.** The `[read]` block /
  `NEXO_MAIL_*` vars (see `Config.read_int`) cap list size, snippet length, batch
  size and body length. As of nexo_ai 0.13 the workflow's `max_turns:` is ALSO a real
  bound: it caps tool ROUNDS (model responses that ask for tools) and raises
  `RubyLLM::ToolRoundLimitError` when spent, which fails the run. Under 0.12 it was
  inert. So a stage that legitimately needs more rounds must have its number raised —
  a second run on a sandbox that still holds the last run's files costs extra rounds,
  because the read-before-write guard makes the model re-read each file it overwrites.
- **Every message is triaged ONCE — `NexoMail::Ledger` is the memory.** One JSON file
  per source in `Config.ledger_dir` (state) holds `seen` (id → activity stamp, for
  every message a committed run was SHOWN, noise included) and `items` (id → the
  extraction item). The listing tools filter against `seen` — `GmailImap::List` before
  the fetch (ids scoped by UIDVALIDITY), `HeyBox` by posting id + `active_at` (so a
  thread that moved comes back), Apple Mail through the `Tools::UnseenOnly` wrapper
  around the MCP `get_emails`/`search` (the server has no cursor; an unparseable
  reply passes through untouched). The agent writes only the NEW items to
  `<source>.new.json` and calls `Tools::CommitExtraction`, which upserts by `id`,
  writes the full `<source>.json` Synthesize reads, and is the ONLY thing that moves
  the cursor. **Listing remembers what it offered in memory only; commit persists
  it** — so a run that dies in between marks nothing read. That is why ledgers are
  process-wide (`Ledger.for(key)`): the listing tool and the commit tool are
  different objects sharing one offered set. The workflow's success test for a source
  is `Ledger#committed?`, NOT the file — `<source>.json` survives from the previous
  run. Ruby still holds no date policy: the agent passes its window as `keep_since`.
  Measured on two back-to-back runs with nothing new in between: reading the inboxes
  went from 7m32s (HEY, 12 calls) + 2m27s (Apple Mail) to 7.3s + 6.5s, each agent
  listing zero messages, writing `[]` and committing. `--reset-ledger` forgets
  everything (use it after changing a triage skill, when old items should be judged
  again).
  Two traps this exposed: (1) **the workflow deletes `<source>.json` before the source
  agent runs** (`CommitExtraction.clear`) — left in place, an agent reads the previous
  run's copy, takes it for "what is already on record", and trims its output to match
  (48 listed, 7 committed); before the ledger that same re-read was an accidental
  memory, which is how Apple Mail showed 45 items from an inbox holding 11 in window.
  (2) the file is written **one item per line**, not pretty-printed — the read tool
  pages by lines and characters and 204 pretty items were 2,927 lines. `digest.json`
  follows the same rule (`DigestFile#layout`): a section longer than 1,000
  characters is written one entry per line, because `read_file` cuts a line past
  2,000 characters.
- **The digest is KEPT, not rebuilt — `NexoMail::DigestFile` decides which run this
  is.** After the inboxes commit, the workflow calls `DigestFile.plan!`: **`:full`**
  (no `digest.state` beside the ledgers, or more than `Config.digest_rebuild_over`
  items waiting — default 60), **`:update`**, or **`:current`** (nothing waiting and
  the digest was built today → Synthesize, Publisher and Archivist do not run at
  all). Each ledger keeps a `pending` list: `Ledger#commit` adds the item keys,
  `Tools::NewItems` hands them to the builder (`take_pending`, remembered in memory),
  and only `Tools::CommitDigest` strikes them off — the ledger's own two-step, one
  stage later, so a failed synthesis leaves them pending. **The model never writes
  `digest.json`.** It writes `digest.update.json` — top-level keys to replace whole,
  plus an `edit` key that puts/drops single entries of `action`/`fyi` (by `id`),
  `stories` (`title`), `people` (`name`), `topics` (`topic`) — and calls
  `commit_digest`. `DigestFile` replaces exactly that, never looks at content, and
  reports list lengths beside the stated `counts`. The workflow suspends unless
  `DigestFile.committed?` — NOT on the file's existence, which is how a failed
  synthesis used to pass as done behind the previous run's `digest.json`.
  `--rebuild-digest` deletes `digest.state`; `--reset-ledger` does
  too. Measured on one day's real mail: full build 4m17s / 11 calls (96 items); an
  update with 1 new item 49s; with 6 new items, two carrying payments, 2m26s; nothing
  new 14s for the whole run. What was learned getting there: replacing whole lists
  made an update write 13KB to place five items (2m36s) — hence `edit`; and one
  pending payment sent the builder back through every extraction file to re-send all
  the charges (3m11s) — which is why money now comes from `MoneyReport` reading the
  record. What remains is model thinking time,
  not bytes. The seed-once gotcha applies: `inbox_synthesis` must be copied over an
  existing install, or the agent follows the old skill and writes `digest.json`
  directly (which then never commits, and the run suspends).
- **Every item has a LANE, and the lane — not one window — decides where it shows
  and how long it lives.** `conversation`, `money`, `dev`, `reading`, `opportunity`,
  `jobs`, `ephemeral` (`SenderMemory::LANES`). The rules are skill text: `email_triage`
  assigns the lane (plus a `dev` record keyed by `ref`, e.g. `owner/repo#123`, and an
  `opportunity` record with `deadline`/`starts`); `inbox_synthesis` §4b maps lanes to
  digest sections — `dev` (ONE entry per `ref`, however many notifications and
  inboxes), `opportunities`, `jobs`, `counts.ephemeral` — and gives each its lifetime.
  Ruby only carries it: `CommitExtraction(keep_by_lane:)` takes a cutoff per lane,
  and `Tools::Today` returns `days_ago` (7/14/30/90) so the model never subtracts
  days — still a clock, not a policy. The three new lists are entry-editable in
  `DigestFile::EDITABLE` and rendered by the template (`devSec`, `oppSec`, `jobsSec`).
- **`NexoMail::SenderMemory` asks the lane question once per sender.** Two sources,
  not equals. FIXED: the reader's `Config.senders_file` (`senders.toml`, address or
  domain → lane; address beats domain, a domain covers its subdomains). It is
  authoritative — `CommitExtraction` stamps it over whatever the model wrote, and a
  sender fixed as `ephemeral` never reaches the model: the listing tools hand its
  rows to `Ledger#route` as finished minimal items (`routed: true`), committed with
  the rest. LEARNED: a per-address tally in `ledger/senders.json` of the lanes first
  filings were given; unanimous after `SETTLE` (2) filings, it rides on listing rows
  as a `lane` HINT the model may override. A learned `ephemeral` is only ever a hint —
  auto-skipping on a guess would silently drop the one refund notice from a shop
  that usually sends promotions. `--reset-ledger` clears the tally with the ledgers.
- **HEY fetches more than it shows.** `hey box --limit` is `Config.hey_fetch_limit`
  (200); the ledger filter runs first and only the newest `hey_box_limit` (40)
  untriaged postings per box are offered, the rest reported as `more_waiting` and
  listed next run. Capping the fetch itself meant mail past the newest 40 of a box
  was never triaged at all.
- **Snapshots live in `Config.snapshots_dir`** (state), separate from the sandbox.
  Because the sandbox is fenced, agents reach snapshots ONLY via the `ArchiveRun` /
  `PruneSnapshots` tools. Each run archives `digest.json` + `dashboard.html` +
  `inbox-digest.md`; retention default 20 (`NEXO_MAIL_SNAPSHOTS_KEEP`).

## Gotchas (learned the hard way)

- **`Kernel#warn` is a no-op here** — a native gem (lipgloss/glamour) sets
  `$VERBOSE = nil`, which disables `warn`. Use `$stderr.puts` for user-facing errors.
- **lipgloss / glamour ship precompiled native builds** (arm64), not pure Ruby.
  Glamour custom theme: `Glamour.render_with_style(md, style_hash, width:)`; hex
  colors work.
- **Multiple system messages.** Nexo/ruby_llm store each instruction (agent + sandbox
  + skill + prompt fragments) as a SEPARATE `role: :system` message. Most templates
  accept this; strict llama.cpp Jinja templates ("System message must be at the
  beginning") do not — fix that on the server via `--chat-template`/`--chat-template-file`
  or by editing the GGUF `tokenizer.chat_template`, not in the app.
- **`net-imap` is a declared dep** (no longer stdlib in Ruby 3.4+/4.0).
- **`data/**` must stay in `spec.files`** or bundled config/skills/themes/templates
  won't ship. Verify a new asset ships: `gem build … && gem unpack …` then `find`.
- **The dashboard is agent-authored, so its safety lives in the skill**
  (`dashboard_designer`): self-contained (no CDN/web-fonts — CSP-free but must open
  from `file://`), render untrusted email text via `textContent` only, embed data as
  a JSON blob with `<` escaped to `<` (defeats a `</script>` breakout), and
  `^https?://`-check any link. There is NO Ruby renderer/fallback — if the Publisher
  fails, `digest.json` is still the durable artifact and the terminal shows the digest.
- **The sandbox `Shell` has a narrowed PATH** (`PATH`/`HOME`/`LANG` only, from the
  parent ENV). A version-managed `ruby` (mise/asdf/rbenv) may not resolve there — pin
  `[dashboard] ruby` to the absolute interpreter (done for this repo → the mise Ruby).
- **Escaping the dashboard JSON blob is done in Ruby, not the model** —
  `render_dashboard.rb` escapes `<>&  ` → `\u00xx` so the untrusted email
  text can't break out of `<script type="application/json">`. Two byte-level traps:
  (1) writing a regex char-class with literal U+2028/U+2029 can get mangled by the
  editor — verify with `grep … | od -c` (the `<>&` path is the security-critical one
  and is plain ASCII); (2) use gsub's **block** form (`{ |c| format("\\u%04x",…) }`),
  not a replacement string, so no backslash gets reinterpreted. Proven offline by
  feeding a `</script>` payload through the renderer.
- **Charset/mojibake in the dashboard:** the generated `dashboard.html` needs BOTH a
  `<meta charset="utf-8">` (it opens from `file://`, where browsers guess the charset)
  AND `JSON.generate(data, ascii_only: true)` in the render script, so accents/arrows/
  emoji embed as `\uXXXX` and never render as `MÃ©xico`/`â†'`. If text is STILL garbled
  after that, the source `digest.json` is double-encoded — check
  `File.read(path).force_encoding("UTF-8").valid_encoding?`; if false, the fault is a
  mail-reading tool's decoding, not the dashboard.
- **Can't fully E2E offline** — the pipeline needs a model + live mail. Offline you
  can verify: boot/eager-load + no leaks, per-agent `.skills`, `--check`, the snapshot
  tools + the **dashboard render** (both deterministic), `standardrb`, gem packaging.
- **`Gemfile.lock` is git-ignored** (gem convention). `.env` and local `sandbox/` too.

## Dependencies

`nexo_ai ~>0.16.1` (which brings `ruby_llm ~>2.2`, MCP included), `mxc` (the OS
sandbox behind `[dashboard] sandbox = "confined"`), `zeitwerk`,
`net-imap`, `toml-rb`, `bigdecimal`, `async ~>2.0`, `lipgloss`, `glamour`. Requires
Ruby **3.3+**. Do NOT add `ruby_llm-mcp` or `ruby_llm-skills`: the first defines the
same `RubyLLM::MCP` constant as ruby_llm 2.x and both pin ruby_llm 1.x.
