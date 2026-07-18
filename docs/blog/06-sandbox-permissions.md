---
title: "The sandbox and permission seams"
date: 2026-07-17
category: desarrollo
tags: [ruby, ai, nexo, sandbox, permissions, security]
series: "Building an email agent with Nexo"
part: 6
---

# The sandbox and permission seams

I have been saying the source agents write their output into "the `:local`
sandbox" without explaining what that is. It is time to, because the sandbox and
permissions are the two things Nexo genuinely adds on top of `ruby_llm`, and they
are what make "read-only email tool" an enforced property instead of a promise in
a prompt.

The two seams answer two different questions. The sandbox is where an agent's
tools act: in memory, on the real filesystem, or inside a container. Permissions
are what those tools are allowed to do: read, write, run shell, fetch the web.
Every capability passes through both. This post covers both, and shows how the
inbox tool uses them to grant exactly one thing beyond reading, and nothing more.

## The four sandbox tiers

The sandbox is chosen with the `sandbox` macro, and there are four tiers.

`:virtual` is the default. It is in memory, with zero host access. A virtual
sandbox has no filesystem to escape and cannot run a shell command at all;
attempting to run one comes back as an error, on purpose. This is the safest
option, and it is what you get if you declare no sandbox at all. An untrusted model
in a virtual sandbox can do nothing to your machine.

`:local` is the real host filesystem and shell, for code you trust in development
or CI. It is what the source agents use, because they need to write a real file you
can open afterward. It is guarded, which I will come back to.

`:docker` and `:apple` run tools inside a throwaway container, hardened by default:
no network, dropped Linux capabilities, a read-only root filesystem with an
ephemeral scratch space. This is the tier for running something you do not trust,
like a classifier over attachments from strangers, without giving it your machine.

There is also a remote tier, where you inject a client that speaks a small
`read`/`write`/`exec`/`close` interface, so you can point the sandbox at a hosted
execution provider with a short adapter and no vendor code in Nexo.

For `nexo_mail` the choice is `:local`. The agents read mail through their tools
and need to write one JSON file each. `:virtual` cannot write a file you can open,
and a container is more isolation than a tool reading your own mail on your own
machine needs.

## How the local sandbox is guarded

`:local` is the real filesystem, so the interesting question is what stops an agent
from writing outside its workspace. Two guards.

The first is path containment. The sandbox is rooted at a working directory, and
every path an agent's tools touch is expanded against that root and must stay
inside it. A path that resolves outside, including through `../`, raises a
`SecurityError`. The second guard resolves symlinks before the check, so a symlink
inside the workspace cannot point at a target outside it.

The source agents are constructed with the workspace as their working directory —
here the workflow builds one from its catalog descriptor:

```ruby
agent = descriptor.build(cwd: Config.sandbox_dir)   # e.g. an EmailSource or AppleMailSource
```

Everything the agent writes lands under `Config.sandbox_dir`. If the model, for any
reason, tried to write to `/etc/something` or `../secrets`, the write would raise
rather than succeed. The agent can write its digest and nothing else.

There is one more piece of hygiene worth knowing: the local sandbox narrows the
environment its shell sees to `PATH`, `HOME`, and `LANG`, plus anything you add
explicitly. A model-driven shell never sees your full process environment, so a
stray command cannot read secrets you happened to have exported.

## The permission modes

The sandbox decides where; permissions decide what. The mode is set with the
`permissions` macro, and there are four.

`:read_only` is the default. Reading and globbing are always allowed. Writing,
running shell, fetching the web, and searching the web are denied. A denied
capability returns an error the model can see and adapt to; it never raises. So an
agent can look but not touch, and asking it to write simply comes back as "not
allowed."

`:auto` allows everything. `:ask` defers each sensitive action to a callback you
provide, so you can prompt a human. `:approve` is the durable sibling of `:ask`: an
undecided action suspends the whole workflow run and waits, which is the subject of
a later post.

The important structural fact is that read and glob are free, and write, shell,
fetch, and search are all gated. Reading the web is not a read in this model; it is
an escalation, gated exactly like writing a file. That surprises people, and it is
the right default.

## What the inbox tool grants

The source agents need to read mail and write one file. So their permissions are
read-only, with write added:

```ruby
class SourceAgent < Nexo::Agent
  sandbox     :local
  permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write])
end
```

The `allow` list adds `:write` on top of the read-only baseline. That is the single
capability granted beyond reading. There is no `:shell`, no `:fetch`, no `:search`.

This interacts with the sandbox in a way worth making explicit. Nexo attaches its
`Shell` tool only when the sandbox can run a shell and the permission mode allows
it. A `:local` sandbox can run shell, but these agents do not permit it, so no
`Shell` tool is ever attached. The model is not told a shell exists. You cannot
misuse a capability that was never offered, which is a stronger guarantee than
telling the model not to use it.

## The read-only story, in one place

By now the tool reads three inboxes through three different integrations, and each
one is read-only for a different, concrete reason. It is worth seeing them together,
because none of them rely on the prompt:

Apple Mail is reached over MCP, and the `mcp_allow` list contains only read tools.
The gate denies send and delete by name, even though the server exposes them.

Gmail is read over IMAP with `EXAMINE`, a read-only select, and `BODY.PEEK`, which
does not set the seen flag. The server refuses changes and reading marks nothing.

HEY is read through its CLI as an argv array with hardcoded read subcommands, run
without a shell, so there is no way to reach a write subcommand or inject one.

And underneath all three, the sandbox is `:local` with only `read`, `glob`, and
`write`, fenced to the workspace. The agents can write their own digest files and
touch nothing else on the machine.

Four independent mechanisms, none of them a request to the model to behave. That is
what I mean when I call the tool read-only by construction.

## A note on the write guard

Since the agents do write files, one built-in behavior is worth knowing. On a real
filesystem, `WriteFile` will refuse to overwrite a file the agent has not read
first, and will refuse to overwrite a file whose modification time changed since it
was read. New file writes go through freely. This prevents an agent from clobbering
something it never looked at, or racing over an external change. On the virtual
sandbox the guard is skipped, since there is no real mtime. It rarely comes up when
each agent writes its own fresh file, but it is there.

## Where this leaves us

The tool now reads three inboxes concurrently and writes each source's structured
output into a fenced workspace, read-only by construction, with only write granted
beyond reading. What it does not yet have is a single, coherent result. There are
three separate JSON files, not one briefing. The next post adds a synthesis step
that merges them into one digest, and introduces the design rule that keeps the
library thin: the Ruby orchestrates and provides tools, and the agents and skills
do the judgment.

## What will trip you up

The bare `:ask` symbol does not prompt anyone. `permissions :ask` with no callback
resolves to a gate with nothing to ask, so sensitive actions are denied, not
prompted. To actually prompt, pass a built `Nexo::Permissions` with an `on_ask`
callback. This bites people who expect `:ask` to be interactive out of the box.

Fetch and search are denied by default, like shell. If you want an agent to read a
web page, granting the capability is an escalation you opt into with `:fetch` in the
allow list plus a host allow-list, not something reading implies.

The virtual sandbox cannot run shell, and that is not a gap. If you need shell, use
`:local` or a container. Do not read the virtual sandbox's refusal as a bug.

Container defaults are strict for a reason, and they break naive installs. A
`:docker` sandbox runs with no network, so `npm install` or `bundle install` inside
it fail. Bake dependencies into the image or open the network deliberately, and
remember the container's scratch space is ephemeral, so persist anything you need
through a writable bind.

Next: [Part 7, merging the sources into one digest](07-synthesis-pipeline.md).
