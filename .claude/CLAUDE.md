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
deterministically; the agent decides *to* call it). Accepted tradeoff: money
arithmetic runs in the model now, not Ruby.

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
  tools/                    # CliReader, HeyBox/HeyThread, GmailImap(::List/::Read),
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
   + `digest.json` (the workflow stages both into the sandbox first). The design is
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
- **HEY has THREE boxes** — `imbox` (people → action/fyi), `feed` (newsletters →
  tag `topics`), `papertrail` (receipts → extract `payment`). The `HeyBox` tool
  takes a `box` param; the skill tells the agent to pull all three.
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

`nexo_ai ~>0.7`, `ruby_llm-mcp`, `ruby_llm-skills`, `zeitwerk`, `net-imap`,
`toml-rb`, `async ~>2.0`, `lipgloss`, `glamour`. Requires Ruby **3.3+**.
