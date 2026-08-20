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
model; it was measurably wrong, so it now runs in `Tools::SumPayments`, which the
agent calls — the carve-out, not an exception to it.

## Commands

```sh
bundle install
exe/nexo-triage --check              # preflight: model + services readiness
exe/nexo-triage --help               # config + per-service setup docs
exe/nexo-triage                      # run a triage (needs a model + services)
exe/nexo-triage --prune-snapshots 20 # agent-driven prune, keep newest 20
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
  sources.rb                # NexoMail::Sources — the source catalog (descriptors)
  agents/                   # SourceAgent base + EmailSource (data-driven, tool-based
                            #   Gmail/HEY) + AppleMailSource (MCP), Synthesize (digest),
                            #   Publisher (dashboard), Archivist
  tools/                    # CliReader, Pool, Hey/HeyBox/HeyThread, CappedTool,
                            #   Today, SumPayments (deterministic primitives),
                            #   GmailImap(::List/::Read/::Mime/::BodyPart),
                            #   ArchiveRun, PruneSnapshots
  workflows/                # MultiInboxTriage < Nexo::Workflow (orchestration only)
data/                       # PACKAGED: config.example.toml, skills/, themes/, prompts/
  skills/                   # email_triage, financial_summary, interest_radar (extract),
                            #   inbox_synthesis (digest), dashboard_designer (HTML),
                            #   snapshot_keeper (archive/prune)
exe/nexo-triage             # 3-line shim → NexoMail::CLI.run(ARGV)
```

## Pipeline (agent + skills driven)

1. **Source agents** (AppleMail/Gmail/HEY, parallel) extract each inbox → a
   structured JSON array file (`gmail.json`, …). Skills: `email_triage`,
   `financial_summary`, `interest_radar`. The workflow walks `NexoMail::Sources.all`
   — one **descriptor** per source (name, file, `prompt_key`, tools, availability).
   Tool-based sources (Gmail, HEY) share ONE `Agents::EmailSource` built from a
   descriptor; adding such a service is a descriptor, not a class. Apple Mail keeps
   its own `AppleMailSource` because its `mcp` macro is class-level.
2. **Synthesize** reads those files → writes `digest.json` + `inbox-digest.md`:
   merge, **cross-source dedupe**, money rollups, schedule, stories, per-person
   detail, topic briefings. Skills: `inbox_synthesis`, `financial_summary`,
   `interest_radar`.
3. **Publisher** renders `dashboard.html` by RUNNING the `dashboard_designer`
   skill's bundled `scripts/render_dashboard.rb` over `assets/dashboard-template.html`
   + `digest.json` (the workflow STAGES the skill's `scripts/`+`assets/` into the
   sandbox first, so the agent's gated read/glob tools can reach them). The design is
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
  the CLI mutates `RubyLLM.configure` globally and calls
  `Agents::SourceAgent.configure_model!(m)` (sets provider/model on every triage
  class) — do NOT reach for `RubyLLM.context`.
- **Skills** load from the XDG skills dir (`Config.skills_dir`), seeded copy-if-missing
  from `data/skills/`. Editing the XDG copy is the override. `nexo`'s `skills_path`
  is a single dir with no built-in precedence — that's why we seed. New skill dir →
  bootstrap seeds it automatically (`data/skills/*`); no code change needed.
  **Seed-once gotcha:** bootstrap copies *only if absent*, so editing a packaged
  `data/skills/*/SKILL.md` does NOT reach an existing install — the user's stale
  `~/.config/nexo-mail/skills/<name>/SKILL.md` wins. When iterating on skills for a
  live user, `cp` the updated file over their `Config.skills_dir` copy (or delete it
  so bootstrap re-seeds). This is by design — editing the XDG copy IS the override.
- **Downstream agents inherit `SourceAgent` but must RESET skills** with a direct
  `@skills = %i[...]` ivar assignment (see `Synthesize`/`Publisher`/`Archivist`).
  Nexo's `inherited` copies `@skills` (a CONFIG_IVAR) to the subclass, and the
  `skills` *macro only accumulates* — so `skills :x` would ADD to the inherited
  extraction skills instead of replacing them. `instructions`, by contrast, replaces.
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
- **The Publisher's sandbox is CONFIG-DRIVEN and Nexo owns it.**
  `Agents::Publisher.sandbox` is a lazy READER override returning `:local` or a
  container options Hash from `[dashboard] sandbox` / `image` (local|docker|apple,
  default local). Because the agent RESOLVES it rather than being handed one, Nexo
  also closes it in `Agent#close` — never inject via `new(sandbox:)` here, that makes
  it borrowed and you own the teardown (a leaked container per run). The container is
  `network: :none` + cap-drop + read-only rootfs; `readonly_rootfs` is forced FALSE
  for `apple`, which cannot write under it. `hardening_gaps` is emitted, not ignored.
- **Containerized, `digest.json` goes IN and `dashboard.html` comes OUT by hand.**
  Docker REFUSES a bind at the tmpfs scratch path (`Duplicate mount point:
  /workspace`, verified), so there is no shared-directory shortcut. `hand_over_inputs`
  copies the digest sandbox-to-sandbox reading from the WORKSPACE (the file the
  previous stage wrote is the source of truth, not the run record — the run record
  copy may be missing if synthesis failed to record). `collect_declared` picks the
  reader with `shares_workspace?`: Nexo's `collect_artifacts` resolves declared names
  through the WORKFLOW's sandbox and cannot see a container's, so `import_artifacts`
  reads through `agent.sandbox` and MIRRORS into the workspace root — the Archivist
  and the CLI both look there. `shares_workspace?` tolerates a duck with no
  `#sandbox`, matching Nexo's own guard.
- **Two `[dashboard]` knobs change meaning in a container.** `ruby` pins a HOST
  interpreter, so `publisher_ruby` uses the image's `ruby` instead; an absolute
  `template`/`renderer` override is a host path the container cannot see, so
  `in_workspace` falls back to the staged copy and emits `publisher_override_ignored`.
  Both are loud, never silent.
- **A skill states its needs in `compatibility:`** — the Agent Skills spec's own
  frontmatter field, which nexo_ai >= 0.9 appends to the model's instructions.
  `dashboard_designer` uses it to say it needs a Ruby 3.0+ interpreter and the shell
  tool, and that there is no fallback. Subject to the SAME seed-once gotcha as the
  rest of the skill: editing `data/skills/*/SKILL.md` does not reach an existing
  install — `cp` it over `Config.skills_dir`.
- **`SourceAgent.configure_model!` has a hardcoded roster** of every triage class
  (`[SourceAgent, EmailSource, AppleMailSource, Synthesize, Publisher, Archivist]`).
  Add any NEW agent CLASS here or it runs with no model/provider set. A new
  tool-based *source* adds only a `Sources` descriptor — no class, so the roster
  stays fixed; a new agent class (or an MCP source like Apple Mail) still needs a
  roster entry.
- **Custom `source_tools` are NOT gated by Nexo permissions** (only the built-in
  sandbox tools + MCP allow-list are). `HeyBox`, `GmailImap`, `ArchiveRun`,
  `PruneSnapshots` run as plain `RubyLLM::Tool`s — their safety is your job
  (read-only mail by construction; `PruneSnapshots` bounded to `Config.snapshots_dir`).
- **Per-agent prompt fragments**: `SourceAgent#chat` appends `common.md` +
  `<prompt_key>.md` from `Config.prompts_dir` when present. Each source defines
  `self.prompt_key`.
- **Read-only by construction**: MCP fail-closed allow-list (Apple Mail), IMAP
  `EXAMINE` (Gmail), hardcoded CLI read subcommands via argv arrays (HEY). Agents run
  a `:local` sandbox fenced to `Config.sandbox_dir` with only `:read/:glob/:write`.
  **One scoped exception:** the `Publisher` agent alone also gets `:shell`, purely to
  run the bundled dashboard render script — it reaches NO mail (no mail tools). Every
  mail-reading agent stays `:read_only` with no shell (verify:
  `GmailSource.permissions.authorize!(:shell)` raises; `Publisher`'s does not).
- **Skill-bundled files are AUTO-RESOLVED, never path-joined.** `scripts/`,
  `assets/`, `references/` is *ruby_llm-skills'* convention, and `Nexo::Skills.find`
  already returns a `Skill` exposing `#scripts`/`#assets`. `Config.skill_script` /
  `#skill_asset` wrap that; `dashboard_renderer`/`dashboard_template` take the SKILL
  as an argument and the workflow passes `Agents::Publisher.skills.first`. Nothing
  names a skill or a filename outside the agent's own `@skills`, so renaming either
  needs no code change — verified by renaming both the skill dir and its files.
  A new script-bearing skill needs NO Config accessor.
  **Nexo deliberately does not attach the gem's `SkillTool`** (it does ungated
  `File.read`), and `Sandboxes::Local` is SINGLE-ROOTED — every read/glob/write is
  guarded against one `cwd` — so a skill's files are invisible to the gated tools
  while they live outside the sandbox.
- **The workflow STAGES skill resources into the sandbox** (`stage_skill_resources`),
  copying every `scripts/`+`assets/` file the skill ships and preserving that layout,
  so the render command is workspace-relative and the agent can `glob scripts/*`
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
- **`hey threads` wants the TOPIC id, not the posting `id`.** The topic id lives
  only inside `posting["app_url"]` (`https://app.hey.com/topics/<TOPIC_ID>`) and is
  a different number; reading by posting id always 404s. `Hey.thread_id` parses it,
  the listing exposes it as `thread_id`, and a `kind: "bundle"` posting (app_url
  `/contacts/…`) has none — it simply cannot be read.
- **`hey` cannot be called concurrently — `Tools::Hey::LOCK` is the invariant.**
  It serializes on the macOS keyring, so parallel invocations race and every loser
  exits 3 with "not logged in" (measured: 1 in flight → 12/12 ok, 2 → 9/12,
  3 → 6/12, 4 → 3/12). EVERY `hey` invocation goes through `Tools::Hey.run`, which
  holds a process-wide `Mutex` for the whole subprocess — so no caller can race it:
  not a `Pool` fan-out, not two tool calls running together, not the `Sources`
  availability probe. With the lock in place the same 8-way fan-out is 8/8. Never
  shell out to `hey` directly; add it to `Hey.run`.
- **Concurrency here is fibers, not threads.** `Config.tool_concurrency` defaults to
  **`:fibers`**, so ruby_llm overlaps multiple tool calls from one turn on async —
  the same reactor `Nexo.concurrent` already runs the source agents in.
  `Tools::Pool` (the in-tool fan-out) is a thin wrapper over the SAME machinery —
  `RubyLLM::ToolConcurrency.run` — so one setting governs both axes and Pool owns no
  reactor plumbing. Two things it must add, and the reasons they are not optional:
  ToolConcurrency has NO in-flight bound (one task per entry), so `Pool` slices into
  chunks of `size` — Gmail caps simultaneous IMAP connections per account and `hey`
  serializes on the keyring; and ToolConcurrency RE-RAISES the first error and
  abandons the rest, so the per-item `guard` (→ `{error:}`) is what keeps one dead
  thread id from sinking a batch of fifteen. Measured: peak-in-flight tracks `size`
  exactly (4→4, 8→8), order preserved, and it nests correctly inside the reactor the
  workflow already runs. This works because Async's scheduler hooks `process_wait`,
  `io_read` and `io_wait`: `Open3.capture3` and `Net::IMAP` both YIELD rather than
  block (measured: 4×`sleep 0.4` 1.64s → 0.41s; 4 IMAP connects 0.95s → 0.17s).
  Ruby's `Mutex` is fiber-aware, so `Hey::LOCK` yields instead of deadlocking the
  reactor. `async` is a hard dep of nexo_mail but only a SOFT one of nexo_ai.
- **The read tools are BATCHED and return JSON STRINGS.** `GmailImap::Read` takes
  `uids: []`, `HeyThread` takes `thread_ids: []` — one model round trip instead of
  N, and for Gmail one IMAP session instead of N. Both listings carry a `snippet`
  so most messages never need a body read at all. Every tool returns
  `JSON.generate(...)`: ruby_llm `to_s`-es a non-Content result (`chat.rb:383`), so
  a Hash would reach the model as Ruby `inspect`, not JSON.
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
  "accepted tradeoff". `Tools::SumPayments` (attached to `Synthesize`) is a pure
  calculator: BigDecimal addition, grouped per currency, NEVER converting between
  them, and it makes no judgments — it does not know the date, does not filter, and
  refuses to guess a direction (unrecognised ones come back in `needs_direction`,
  uncounted). Each currency is a self-contained block holding its own `charges` list
  AND the totals of that list, so the two cannot drift — they did: a run reported USD
  `charged: 289.00` against its own list summing to 269.00 (true figure 1218.00), and
  MXN `refund: 7,979.84` against 7,899.98 with `count: 5` for four entries.
- **Never merge currencies.** There is no FX rate anywhere in this project. The
  dashboard template used to sum `charged`/`due`/`paid` ACROSS currencies and label
  the result with the dominant one; it now renders one block per currency. Money is
  separated by currency in `SumPayments`, in `digest.json`'s `finance.by_currency`,
  in the dashboard, and in `inbox-digest.md`.
- **Read shaping is config, and it is the only real bound.** The `[read]` block /
  `NEXO_MAIL_*` vars (see `Config.read_int`) cap list size, snippet length, batch
  size and body length. The workflow's `max_turns:` is INERT — `Nexo::Loops::RubyLLM`
  accepts and ignores it — so these caps plus the skill's two-read budget are all
  that stands between you and a runaway read loop.
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

`nexo_ai ~>0.9`, `ruby_llm-mcp`, `ruby_llm-skills`, `zeitwerk`, `net-imap`,
`toml-rb`, `async ~>2.0`, `lipgloss`, `glamour`. Requires Ruby **3.3+**.
