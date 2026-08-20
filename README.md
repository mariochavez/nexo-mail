# Nexo Mail Agent (`nexo_mail`)

AI email triage for **Apple Mail, Gmail & HEY** — one prioritized markdown digest.
Built on [`nexo_ai`](https://rubygems.org/gems/nexo_ai) + [`ruby_llm`](https://github.com/crmne/ruby_llm),
with a Catppuccin-themed terminal UI. **Read-only**: it reads and searches mail and
writes only into a sandboxed workspace — it can't send, delete, flag, or move mail.

One executable, **`nexo-triage`**, runs a Nexo Workflow: one read-only triage agent
per source classifies its inbox and writes a digest fragment into the sandbox; a
merge agent combines them into one `inbox-digest.md`. Sources that aren't configured
are skipped (with a reason); the run continues with whatever's available.

## Install

```sh
gem install nexo_mail        # or add `gem "nexo_mail"` to a Gemfile
nexo-triage --help           # how to configure everything
```

Requires Ruby 3.2+ and macOS for Apple Mail. First run creates the config under XDG:

```
$XDG_CONFIG_HOME/nexo-mail/          (default ~/.config/nexo-mail/)
  config.toml                        # your config (annotated; edit it)
  skills/email_triage/SKILL.md       # classification rules (override the bundled default)
  prompts/                           # optional per-agent prompt fragments
$XDG_STATE_HOME/nexo-mail/sandbox/   (default ~/.local/state/…) — fragments + the digest
```

## Configure — `config.toml`

Precedence for every setting: **`NEXO_MAIL_*` env var > `config.toml` > default**.
Any string value may use `${VAR}` / `${VAR:-fallback}` interpolation.

```toml
# Models — no default. The FIRST is used unless `--model <alias>` / NEXO_MAIL_MODEL.
[[models]]
alias    = "local"
provider = "ollama"                  # any ruby_llm provider: ollama, openai, anthropic, …
model    = "llama3.1"
api_base = "http://localhost:11434/v1"
api_key  = ""

[[models]]
alias    = "cloud"
provider = "openai"
model    = "glm-5.2:cloud"
api_base = "https://ollama.com/v1"
api_key  = "${OLLAMA_API_KEY}"        # kept out of the file via env interpolation

[services.gmail]                      # read-only IMAP with a Gmail App Password
address      = "${GMAIL_ADDRESS}"
app_password = "${GMAIL_APP_PASSWORD}"

[services.apple_mail]
mcp_command = "apple-mail-mcp"

[theme]
flavor = "mocha"                      # latte (light) · frappe · macchiato · mocha (dark)
```

Run `nexo-triage --help` for the full per-service setup (apple-mail-mcp install +
indexing, the Gmail App Password steps, building the `hey` CLI).

## Run

```sh
nexo-triage                 # triage all configured sources → digest
nexo-triage --check         # preflight: which model + services are ready
nexo-triage --model cloud   # pick a configured model by alias
nexo-triage --theme latte   # override the theme for this run
RUBYLLM_WIRE=1 nexo-triage   # show the raw ruby_llm/MCP logs
```

You get a styled run: a live spinner + elapsed clock while sources triage
concurrently, a per-source outcome summary (`✓` done · `✗` failed · `⊘` skipped, with
reasons), and the unified digest rendered as markdown into
`$XDG_STATE_HOME/nexo-mail/sandbox/inbox-digest.md`.

Each agent **declares** what it produces, so the run itself carries the deliverables
(`digest.json`, `inbox-digest.md`, `dashboard.html`, the per-source extractions) —
not just the directory they happened to land in. The last line of a run tells you
what was recorded.

`--check` also probes the **sandbox**, not only your services: the render stage needs
a Ruby interpreter reachable from the sandbox shell, which runs with a narrowed
`PATH`, so a version-managed `ruby` (mise/asdf/rbenv) may not resolve there even
though it resolves in your terminal. If it doesn't, preflight says so and you pin
`[dashboard] ruby` to an absolute path — the run fails fast rather than half-working.

## Customize

- **Classification & VIP senders** — edit `~/.config/nexo-mail/skills/email_triage/SKILL.md`
  (seeded from the bundled default on first run; your edits win and survive upgrades).
- **Per-agent prompt fragments** — drop Markdown in `~/.config/nexo-mail/prompts/`:
  `common.md` (appended to every agent) or `apple_mail.md` / `gmail.md` / `hey.md` /
  `merge.md`. They're appended to the agent's instructions, not replaced.
- **Theme** — `[theme] flavor` (or `NEXO_MAIL_THEME_FLAVOR` / `--theme`). Catppuccin
  Latte / Frappé / Macchiato / Mocha, applied to both the UI and the digest.

## Safety model

- **Read-only mail, by construction.** Apple Mail: Nexo's MCP gate is fail-closed
  (only the read tools are allowed). Gmail: read-only IMAP `EXAMINE` mode. HEY: CLI
  wrappers shell out via argv arrays (no injection) to hardcoded read subcommands.
- **Fenced writes.** Agents run a `:local` sandbox rooted at the XDG sandbox dir;
  path traversal and symlink escapes are rejected.
- **Least privilege.** Every agent runs under `:read_only` with only `:read/:glob/:write`.
  The Publisher alone also gets `:shell`, purely to run the bundled render script; it
  attaches no mail tools at all.
- **That one shell can leave the host.** `[dashboard] sandbox = "docker"` renders the
  dashboard inside a throwaway container — no network, dropped capabilities, read-only
  rootfs — with `image` picking the interpreter. `--check` probes whichever you choose.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the design.

## Layout

```
lib/nexo_mail/
  agents/      SourceAgent + AppleMailSource / GmailSource / HeySource / MergeDigests
  tools/       CliReader, Pool, Hey/HeyBox/HeyThread, CappedTool,
               GmailImap(::List/::Read/::Mime/::BodyPart)
  workflows/   MultiInboxTriage
  config.rb    XDG/TOML config + ${VAR} + ENV precedence
  bootstrap.rb first-run provisioning
  theme.rb     Catppuccin palettes + Glamour styles
  cli.rb       the runner
data/          bundled config.example.toml, skills, themes, prompts README
exe/nexo-triage
```
