# nexo_mail — project guide for agents

Read-only AI email triage, packaged as a Ruby gem. It reads Apple Mail, Gmail, and
HEY, and produces one prioritized markdown digest (Action / FYI / Noise). Built on
`nexo_ai` (agent harness) + `ruby_llm`. Executable: `nexo-triage`.

## Commands

```sh
bundle install
exe/nexo-triage --check          # preflight: model + services readiness
exe/nexo-triage --help           # config + per-service setup docs
exe/nexo-triage                  # run a triage (needs a model + services)
RUBYLLM_WIRE=1 exe/nexo-triage   # show raw ruby_llm/MCP logs
gem build nexo_mail.gemspec       # package (data/** must be included)
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
  cli.rb                    # NexoMail::CLI — the runner (OptionParser + UI)
  agents/                   # SourceAgent + AppleMail/Gmail/Hey source + MergeDigests
  tools/                    # CliReader, HeyImbox/Thread, GmailImap(::List/::Read), Gws*
  workflows/                # MultiInboxTriage < Nexo::Workflow
data/                       # PACKAGED assets: config.example.toml, skills/, themes/, prompts/
exe/nexo-triage             # 3-line shim → NexoMail::CLI.run(ARGV)
```

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
  is a single dir with no built-in precedence — that's why we seed.
- **Per-agent prompt fragments**: `SourceAgent#chat` appends `common.md` +
  `<prompt_key>.md` from `Config.prompts_dir` when present. Each source defines
  `self.prompt_key`.
- **Read-only by construction**: MCP fail-closed allow-list (Apple Mail), IMAP
  `EXAMINE` (Gmail), hardcoded CLI read subcommands via argv arrays (HEY). Agents run
  a `:local` sandbox fenced to `Config.sandbox_dir` with only `:read/:glob/:write`.

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
- **`data/**` must stay in `spec.files`** or bundled config/skills/themes won't ship.
- **`Gemfile.lock` is git-ignored** (gem convention). `.env` and local `sandbox/` too.

## Dependencies

`nexo_ai ~>0.7`, `ruby_llm-mcp`, `ruby_llm-skills`, `zeitwerk`, `net-imap`,
`toml-rb`, `async ~>2.0`, `lipgloss`, `glamour`. Requires Ruby **3.3+**.
