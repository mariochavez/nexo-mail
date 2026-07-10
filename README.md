# Apple Mail triage agent

A tiny [Nexo](../../maquina/nexo) agent that triages your Apple Mail inbox with a
**local** model and writes a markdown digest. It reaches Mail through the
`apple-mail-mcp` MCP server and is **strictly read-only** — the permission gate
denies send/delete/flag/move even though the server exposes them.

## Pieces

| File | Role |
|------|------|
| `lib/mail_triage_agent.rb` | The `MailTriage < Nexo::Agent` class + LLM/MCP wiring |
| `skills/email_triage/SKILL.md` | How-to-classify skill (copied from Nexo, adapted for Apple Mail) |
| `triage.rb` | Runner: one prompt → prints the digest |

## Setup

1. **Local LLM** — an OpenAI-compatible server (MLX / LM Studio / llama.cpp)
   serving `Ornith-1.0-9B-4bit` at `http://127.0.0.1:8090/v1`. The agent talks to
   it via ruby_llm's `:openai` provider with the base URL repointed; `Ornith` is
   not in ruby_llm's registry, so the agent sets `assume_model_exists true`.

2. **apple-mail-mcp** — install/launch however your server documents it. The agent
   spawns it over stdio with `command: "apple-mail-mcp"`.

3. Install and run:

   ```sh
   bundle install
   ruby triage.rb
   ```

## Override with env vars

```sh
LLM_API_BASE=http://127.0.0.1:8090/v1 \
LLM_API_KEY=local-ai \
LLM_MODEL=Ornith-1.0-9B-4bit \
MAIL_MCP_COMMAND=apple-mail-mcp \
ruby triage.rb
```

## ⚠️ Verify the MCP tool names

`apple-mail-mcp` implementations differ. The `mcp_allow` list in
`lib/mail_triage_agent.rb` matches the installed build's reported tools
(`list_accounts`, `list_mailboxes`, `get_emails`, `search`, `get_email_links`,
`get_email_attachment`). If your server names tools differently, update
`mcp_allow` **and** the tool-call examples in `SKILL.md` to match — any name not
on the allow-list is denied by the gate (fails closed).
