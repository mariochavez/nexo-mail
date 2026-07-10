# Nexo Mail Agent — AI email triage for Apple Mail, Gmail & HEY

An AI agent that **triages your email and writes a prioritized markdown digest**,
built on the [`nexo_ai`](https://rubygems.org/gems/nexo_ai) agent harness. It reads
your inbox, classifies each thread (needs-action / FYI / noise), and produces a
concise "what deserves your attention" digest — driven by a model of your choice
(default: `glm-5.2:cloud` via Ollama).

It triages three mail sources in one run:

| Source | Reached via | How |
|--------|-------------|-----|
| **Apple Mail** | [`apple-mail-mcp`](https://github.com/imdinu/apple-mail-mcp) | an MCP server (local, FTS5 search) |
| **Gmail** | IMAP + App Password | read-only IMAP (`net-imap`); no gcloud/OAuth needed |
| **HEY** | [`hey`](https://github.com/basecamp/hey-cli) | the Basecamp HEY CLI, wrapped as read-only tools |

**Strictly read-only mail.** The agents can read and search mail and write digest
files into a fenced `./sandbox` workspace — nothing else. They cannot send, delete,
flag, or move mail. This is enforced, not requested: Apple Mail's write tools are
denied by Nexo's MCP permission gate (fail-closed), Gmail is opened in read-only
IMAP `EXAMINE` mode, and the HEY CLI is exposed only through wrappers that hardcode
read subcommands — the model never gets a general shell.

---

## How it works

One executable, **`exe/nexo-triage`**, runs a **Nexo Workflow**: one read-only
triage agent per source classifies its inbox and writes a digest **fragment** into
`./sandbox`; a **merge agent** then combines the fragments into one unified
`./sandbox/inbox-digest.md`.

**Bulletproof.** Each source is preflight-checked — a missing binary or absent
credentials means that source is **skipped** (with a reason) and the run continues
with whatever's available; a source that errors mid-run degrades to a "failed"
note. The run never sinks because one inbox isn't ready.

Classification logic lives in a **skill** (`app/skills/email_triage/SKILL.md`) — the
buckets, the digest template, and your always-important senders (see *Customizing*).

### Layout (Rails-like)

```
app/
  agents/      SourceAgent + AppleMailSource / GmailSource / HeySource / MergeDigests
  tools/       CliReader, HeyImbox, HeyThread, GmailImap(::List/::Read), Gws* (optional)
  skills/      email_triage/SKILL.md
  workflows/   MultiInboxTriage
config/
  environment.rb   boot: gems, LLM/Nexo config, shared constants, Zeitwerk autoload
exe/
  nexo-triage      the styled runner
```

`app/agents`, `app/tools`, and `app/workflows` are Zeitwerk autoload roots, so
classes are top-level (`SourceAgent`, `HeyImbox`, `MultiInboxTriage`) with no manual
`require`s — matching Nexo's own `app/agents` / `app/workflows` convention.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full design.

---

## Prerequisites

- **Ruby 3.3+** and Bundler — `bundle install`
- **A model.** Defaults target [Ollama](https://ollama.com) serving `glm-5.2:cloud`
  (a cloud model) over its OpenAI-compatible endpoint. Any `ruby_llm`-supported
  model works — see *LLM setup*.
- **macOS** for Apple Mail (the MCP server reads your local Mail store).

```sh
bundle install
```

---

## LLM setup (Ollama, default)

The agents talk to Ollama's **OpenAI-compatible** endpoint (`/v1`). For the default
`glm-5.2:cloud` you need Ollama Cloud access:

```sh
ollama signin                 # authenticate Ollama Cloud
export LLM_API_KEY=...         # your Ollama Cloud key
```

Override any of these via env vars (no code change):

| Var | Default | Meaning |
|-----|---------|---------|
| `LLM_MODEL` | `glm-5.2:cloud` | model tag (`:cloud` ⇒ Ollama Cloud; drop it for a local pull) |
| `LLM_API_BASE` | `http://localhost:11434/v1` | Ollama OpenAI-compatible endpoint |
| `LLM_API_KEY` | *(unset)* | sent as the API key (needed for Cloud models) |

Local model instead? `ollama pull llama3.1` then `LLM_MODEL=llama3.1 exe/nexo-triage`.

---

## Source 1 — Apple Mail (`apple-mail-mcp`)

A local MCP server that reads Apple Mail with a fast FTS5 body search.

```sh
# 1. Install (Python 3.11+, via pipx)
pipx install apple-mail-mcp

# 2. Grant Full Disk Access to your terminal:
#    System Settings → Privacy & Security → Full Disk Access → enable Terminal/iTerm

# 3. Generate the config template (~/.apple-mail-mcp/config.toml)
apple-mail-mcp init

# 4. Build the search index (requires Full Disk Access; re-run to refresh)
apple-mail-mcp index --verbose
```

`config.toml` lets you set a default `account`/`mailbox` and index/server options
(every key also has a matching `APPLE_MAIL_*` env var). The agent launches the
server itself via `command: "apple-mail-mcp"` — you don't run it by hand. Override
the command with `MAIL_MCP_COMMAND` if it's not on your `PATH`.

Read tools used (all others, e.g. send/delete, are denied by the gate):
`list_accounts`, `list_mailboxes`, `get_emails`, `get_email`, `search`,
`get_email_links`, `get_email_attachment`.

---

## Source 2 — Gmail (IMAP + App Password — recommended)

The simplest path — **no gcloud, no GCP project, no extra installs** (Ruby's IMAP
support is a declared gem, `net-imap`). The agent reads Gmail with a **read-only
IMAP** connection (`EXAMINE` mode — it cannot mark, move, or delete anything).

```sh
# 1. Enable 2-Step Verification on the Google account (required for app passwords).
# 2. Create an App Password:  https://myaccount.google.com/apppasswords
# 3. Export the credentials (spaces in the password are ignored):
export GMAIL_ADDRESS='you@gmail.com'
export GMAIL_APP_PASSWORD='xxxx xxxx xxxx xxxx'
```

That's it — `ruby triage_all.rb` will now triage Gmail. Tools used: `List` (recent
INBOX messages: uid, from, subject, date) and `Read` (one message body by uid).

> **Note:** App passwords need 2FA enabled. Some **Workspace** accounts have IMAP or app
> passwords disabled by an admin — personal Gmail is unaffected. IMAP exposes
> folders/messages (not Gmail's native thread/label objects), which is all triage
> needs.

<details>
<summary><b>Alternative: Gmail via the <code>gws</code> OAuth CLI</b> (heavier — needs gcloud + a GCP OAuth client)</summary>

Use this only if you want Gmail's native API (labels/threads) instead of IMAP.
Switch `GmailSource#source_tools` in `app/agents/gmail_source.rb` to
`[CliSources::GmailUnread, CliSources::GmailRead]`, then:

```sh
brew install --cask google-cloud-sdk     # gcloud (or https://cloud.google.com/sdk/docs/install)
gcloud auth login                         # log gcloud in (browser)
npm install -g @googleworkspace/cli       # the Workspace CLI
gws auth setup --login                    # gws provisions an OAuth client via gcloud, then logs in
gws auth status                           # verify (not "auth_method": "none")
```

`gws auth setup` **requires gcloud** — it drives gcloud to create the OAuth client
(`~/.config/gws/client_secret.json`); without it you get `gcloud CLI not found`. If
setup hits a project error, pass one: `gws auth setup --project YOUR_ID --login`.
`gws` is open-source but *not an officially supported Google product*.
</details>

---

## Source 3 — HEY (`hey`, Basecamp CLI)

Built from source (Go 1.26+). The repo ships an `install.sh` that fetches a
prebuilt binary, but **Basecamp has not published any releases yet**, so that
script has nothing to download — build from source until they do:

```sh
# 1. Build & install
git clone https://github.com/basecamp/hey-cli
cd hey-cli
go install ./cmd/...          # installs to $(go env GOPATH)/bin/hey

# 2. Put it on PATH (if GOPATH/bin isn't already), e.g.:
ln -sf "$(go env GOPATH)/bin/hey" ~/.local/bin/hey

# 3. Authenticate (browser OAuth; creds go to the system keyring)
hey auth login
```

Verify with `hey auth status`. Read subcommands wrapped: `hey box imbox` (Imbox
postings) and `hey threads <id>` (one thread). Reply/drafts are never wrapped.

---

## Running

```sh
exe/nexo-triage --help    # how to configure every service (Model, Apple Mail, Gmail, HEY)
exe/nexo-triage --check    # preflight: which services are ready vs. skipped

export LLM_API_KEY=...     # for glm-5.2:cloud via Ollama Cloud (if not already set)
exe/nexo-triage
```

You get a styled run (Charm for Ruby): a live spinner + elapsed clock while the
available sources triage concurrently, a per-source outcome summary
(`✓` done · `✗` failed · `⊘` skipped, with reasons), and the unified digest rendered
as markdown. It's written to `./sandbox/inbox-digest.md` (per-source fragments land
alongside it); the whole `./sandbox/` folder is git-ignored.

`ruby_llm`/MCP logs are silenced by default. To see the raw HTTP/MCP trace for
debugging:

```sh
RUBYLLM_WIRE=1 exe/nexo-triage
```

---

## Customizing

**Always-important senders.** Edit `app/skills/email_triage/SKILL.md` — the
"Always surface" list is always included in the digest. It already includes
`FOTOSETIEMBRE` and `500 Global`; add your own there.

**Classification & digest format.** Everything about *how* mail is bucketed and how
the digest reads lives in that same SKILL.md — no Ruby changes needed.

---

## Safety model

- **Read-only mail, by construction.** Apple Mail: Nexo's MCP gate is fail-closed —
  only the read tools listed above are allowed; send/delete/flag/move are denied and
  return a recoverable error. Gmail: read-only IMAP `EXAMINE` mode — the connection
  can't set flags or modify anything. HEY: the CLI wrapper shells out via **argv
  arrays** (never a shell string, so no injection) to *hardcoded read subcommands*
  only — there is no general shell tool.
- **Fenced file writing.** Every agent writes through a `:local` sandbox rooted at
  `./sandbox`; path traversal and symlink escapes are rejected, so nothing can be
  written outside that workspace.
- **Least privilege.** Agents run under Nexo's `:read_only` permission mode, granted
  only `:read/:glob/:write` (no shell) plus the read MCP tools they need.
