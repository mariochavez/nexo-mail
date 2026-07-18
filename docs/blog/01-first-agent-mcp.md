---
title: "A first agent that reads one inbox over MCP"
date: 2026-07-17
category: desarrollo
tags: [ruby, ai, nexo, mcp, apple-mail, ollama]
series: "Building an email agent with Nexo"
part: 1
---

# A first agent that reads one inbox over MCP

In [the last post](00-agent-model-harness.md) I set up Nexo and ran a five-line
agent on a local model. It could reason about text I handed it, but it could not
reach anything real. In this post I connect it to my Apple Mail inbox and have it
produce a first triage.

The agent will be able to read and search the inbox, and it will be unable to
send, delete, or move any message. That restriction comes from the permission
gate, not from the prompt. This post covers how to attach a mail source over MCP
and how the allow-list enforces read-only access.

## How an agent reaches a service

A model cannot call your APIs on its own. Something has to hand your inbox to it
as a set of tools it can invoke. The clean way to do that, without writing code
tied to one vendor, is the Model Context Protocol, or MCP. A small server
advertises a list of tools like `search`, `get_email`, and `list_mailboxes`, and
the model calls them by name.

What I like about MCP is that it lives at the protocol level and never becomes a
vendor SDK. I do not write Apple-Mail-specific Ruby. I run an MCP server that
knows how to talk to Apple Mail, and my agent talks MCP. If I swap the mail
backend later, the agent code barely moves.

Nexo composes [`ruby_llm-mcp`](https://github.com/patvice/ruby_llm-mcp) so you
attach a server with one macro. For Apple Mail I use
[`apple-mail-mcp`](https://pypi.org/project/apple-mail-mcp/), a local server that
reads Apple Mail's on-disk database:

```sh
pipx install apple-mail-mcp
# Grant your terminal Full Disk Access in System Settings, Privacy and Security
apple-mail-mcp init            # writes ~/.apple-mail-mcp/config.toml
apple-mail-mcp index --verbose # build the search index
```

It runs over stdio, which means Nexo launches it as a subprocess and talks to it
over standard in and out. No network, no port to manage.

## The agent

Here is an agent that reads Apple Mail and writes a short digest:

```ruby
require "nexo"

class AppleMailSource < Nexo::Agent
  model       ENV.fetch("NEXO_MODEL")
  permissions :read_only

  # Apple Mail, reached over MCP. A local stdio server, not a Mail SDK.
  mcp :mail, transport: :stdio, command: "apple-mail-mcp"

  # Read tools only. The server also exposes writes. They are simply not listed.
  mcp_allow %w[
    list_accounts list_mailboxes get_emails get_email
    search get_email_links get_email_attachment
  ]

  instructions <<~TXT
    You triage one Apple Mail inbox. Read recent messages with the mail tools,
    sort each into Action, FYI, or Noise, and write a short markdown digest of the
    ones that matter. Read only. Never send, delete, flag, or move mail.
  TXT
end
```

And running it:

```ruby
agent = AppleMailSource.new
begin
  digest = agent.prompt("Triage my inbox from the last day and give me a digest.")
  puts digest.content
ensure
  agent.close   # tears down the stdio subprocess, more on this below
end
```

```sh
NEXO_MODEL=gemma3:12b ruby apple_mail_source.rb
```

That is a working inbox agent. The `mcp` and `mcp_allow` lines are worth reading
closely, because together they define what the agent can and cannot do.

## How the allow-list enforces read-only access

The `mcp :mail` line attaches the server. On its own that would expose every tool
the server offers, and depending on the server that can include sending and
deleting.

The `mcp_allow` line is the fence. It is an exact-match, fail-closed allow-list.
Under `:read_only`, an MCP tool can be invoked only if its name appears in that
list. Everything else is denied, and the denial comes back as an error the model
can see and adapt to. It never raises and never crashes the loop. This is a
separate axis from the filesystem sandbox we will meet later. MCP tools are gated
by name here, file tools by the sandbox and permission mode.

One important default: `mcp_allow` starts as an empty list. Attach a server under
`:read_only` and forget the allow-list, and the agent can call none of its tools.
Tools are opted in by name, one at a time, rather than dangerous ones being opted
out.

So this agent can `search` and `get_email`. Ask it for more and the gate does its
job:

```ruby
agent.prompt("Delete every newsletter in my inbox.")
# The model reaches for a delete tool. It is not in mcp_allow, so the call is
# denied and returns an error. The model reports that it could not, and moves on.
```

Nothing was deleted, and there is no "do not delete" rule anywhere in the code.
The capability does not exist for this agent. The allow-list is the enforcement,
which is why a tool built this way is safe to run against a real account.

## What the harness provides

Note what the code does not contain. There is no MCP client, no JSON-RPC, no
tool-call parsing, no retry loop, and no permission checks scattered through it. I
declared a model, a permission mode, one server, and an allow-list.

Nexo also attaches its four built-in tools: `ReadFile`, `WriteFile`, `Glob`, and,
only when the sandbox can run commands, `Shell`. The default `:virtual` sandbox
cannot run shell, so no `Shell` tool is ever offered to the model. You cannot
misuse a capability that was never advertised. We only read mail here, so I do not
lean on those yet. In a later post the agent gets a real workspace to write its
digest into.

Progress is observable too. `#prompt` takes a block that streams events as the
agent works, every tool call and result, which is exactly what I wire into a live
status display later on:

```ruby
agent.prompt("Triage my inbox.") do |type, payload|
  case type
  when :tool_call   then warn "calling #{payload}"
  when :tool_result then warn "got #{payload.to_s[0, 80]}"
  end
end
```

## Where this leaves us

There is one agent, reading one real inbox, read only by construction, on a free
local model. But the triage policy, what counts as Action versus Noise and which
senders always matter, is buried in a Ruby heredoc. If I change my mind about
triage I am editing code and redeploying. And a small local model needs more than
three sentences of guidance to classify well.

That is the problem skills solve, and it is where I go next.

## What will trip you up

A few things caught me here, and none of them are hard once you have seen them.

The empty allow-list is the big one. If the agent seems unable to find any tools,
you attached a server but allow-listed nothing. Add the exact read-tool names.
Matching is exact, with no globs and no prefixes.

The gate covers the authority to invoke, not the effects. An MCP tool runs inside
its server, outside Nexo's sandbox. `mcp_allow` decides whether the model may call
`get_email`. It cannot sandbox what the server does once it runs. So allow-list
deliberately. Prefer `:read_only` with a tight list, and do not allow-list a tool
whose side effects you would not want.

Close the agent. The stdio server is a subprocess memoized on the agent instance
and reused across prompts. Call `agent.close`, ideally in an `ensure`, or you will
leak processes.

And keep an eye on small models and system messages. Local models are shakier at
tool calls than hosted ones, so it helps to bake concrete examples into your
guidance, which is exactly what the skill in the next post does. Nexo also stores
the agent instructions, the sandbox description, and each skill as separate system
messages. Most chat templates accept that. A strict llama.cpp template that wants
a single system message at the very beginning does not, and you fix that on the
model server's chat template, not in your app.

Next: [Part 2, moving the triage rules into a skill](02-skills.md).
