---
title: "Moving triage rules into a skill"
date: 2026-07-17
category: desarrollo
tags: [ruby, ai, nexo, skills, ruby_llm]
series: "Building an email agent with Nexo"
part: 2
---

# Moving triage rules into a skill

At the end of [the previous post](01-first-agent-mcp.md) the agent could read an
Apple Mail inbox and produce a digest, but the triage policy lived in a Ruby
heredoc. That has two practical problems. Changing the policy, for example
treating anything from my accountant as Action, means editing code and
redeploying. And three sentences of instruction are not enough for a small local
model to classify consistently.

Nexo separates these concerns. What tools exist and what the agent may do stay in
Ruby, gated by the harness. How the work should be done, meaning the taxonomy and
the house style, moves into a skill: a Markdown file the model reads as guidance.

## What a skill is

A skill is a `SKILL.md` package. It has YAML frontmatter with a `name` and a
`description`, followed by Markdown instructions. Nexo composes
[`ruby_llm-skills`](https://github.com/kieranklaassen/ruby_llm-skills), so you
attach one with a single class macro and no loader setup.

The layout is a directory per skill under your skills path:

```
app/skills/
└── email_triage/
    ├── SKILL.md          # frontmatter and the triage instructions
    └── references/       # optional supporting docs the skill can cite
```

Here is a first `email_triage/SKILL.md`:

```markdown
---
name: email_triage
description: Sort recent messages into Action, FYI, or Noise and summarize the ones that matter. Read-only classification.
---

# Email Triage

Sort every message into exactly one bucket:

| Bucket | Meaning |
|--------|---------|
| Action | The reader must reply, decide, or do something. |
| FYI    | Worth knowing; no response needed. |
| Noise  | Newsletters, receipts, notifications. Left out of the digest. |

Classify from the metadata you already have: sender, subject, snippet. Open a full
message only to settle a genuinely ambiguous case.

## Always surface

Treat any message from these as important, Action if it asks for anything and FYI
otherwise, and always include it:

- Anything from 500 Global (also written 500 Startups or 500.co).
- Anything mentioning FOTOSETIEMBRE.

## Your deliverable

Write this markdown, most important first:

    # Inbox Digest, <date>
    ## Needs action (<n>)
    - <sender>, <subject>: <the one thing that matters>
    ## FYI (<n>)
    - <sender>, <subject>: <why it matters>
    <n> noise messages skipped.
```

You attach it with the `skills` macro and remove the policy from the Ruby:

```ruby
class AppleMailSource < Nexo::Agent
  model       ENV.fetch("NEXO_MODEL")
  permissions :read_only
  mcp :mail, transport: :stdio, command: "apple-mail-mcp"
  mcp_allow %w[list_accounts list_mailboxes get_emails get_email search]

  skills :email_triage      # the policy now lives in Markdown

  instructions <<~TXT
    You triage one Apple Mail inbox using the attached email_triage skill.
    Read recent messages and produce the digest it describes. Read only.
  TXT
end
```

Point Nexo at where skills live. In a Rails app this defaults to `app/skills` and
you would not set it:

```ruby
Nexo.configure { |c| c.skills_path = File.expand_path("skills", __dir__) }
```

The agent behaves the same, but the policy is now a file a non-Ruby collaborator
can edit. Change the taxonomy, add a sender, restyle the digest, all without
touching Ruby or redeploying.

## A skill contributes instructions only

This is the property that keeps skills safe, and it is worth being precise about.
A loaded skill contributes instructions only. It ships no tools of its own, and
attaching one never widens what the agent can do.

A skill can describe using the `search` tool, but if `search` is not in
`mcp_allow`, the description changes nothing. The gate still denies the call.
Nexo also does not attach the progressive-disclosure tool from `ruby_llm-skills`,
which would let the model read files outside the sandbox. The model reaches a
skill's `references/` directory only through Nexo's own gated tools. So a skill is
guidance layered on top of the harness, and it cannot become a hole in it. That
matters in a later post, where a skill ships an actual script.

## Skills accumulate, and a subclass detail

The `skills` macro accumulates. Two lines add up, deduplicated, which lets you
compose a base policy with a per-agent addition:

```ruby
skills :email_triage
skills :formatting     # adds to :email_triage, does not replace it
```

Accumulation interacts with inheritance in a way that is easy to miss. When you
build a base agent and subclass it, which is how the next post shares config
across Apple Mail, Gmail, and HEY, Nexo copies the parent's skill list onto the
child. If a subclass then needs a different set, for example a synthesis agent
that should not inherit the extraction skills, calling `skills` on it adds to the
inherited list rather than replacing it. To reset, assign the class variable
directly:

```ruby
class Synthesize < SourceAgent
  @skills = %i[inbox_synthesis]   # replace, not accumulate
end
```

`instructions` replaces, `skills` accumulates. The asymmetry is deliberate, but it
is the source of a confusing "why does my synthesis agent still have the triage
skill" moment if you do not know it.

## About structured output

The skill above asks for markdown, which is fine for reading in a terminal and
useless for building anything on top of, such as a dashboard, totals, or a
schedule. As the tool grows we want structured data, and the skill is where the
contract is specified. A later version of `email_triage` asks for a JSON array of
items with fields like `bucket`, `category`, `sender`, and `payment`, and
downstream steps build the digest and dashboard from those fields.

Nexo has no structured-output macro. Structured output already lives in
`ruby_llm-schema`, one of the gems Nexo composes. If you want the response
validated against a schema, you use `ruby_llm`'s own `chat.with_schema` on the
chat Nexo built for you, rather than a Nexo wrapper, which does not exist. In
`nexo_mail` I take a more forgiving route for small local models: the skill
specifies the JSON shape, the agent writes it to a file, and Ruby parses it
tolerantly and drops malformed entries. The schema path is available when you want
enforcement. Either way, the contract is described in the skill.

## Shipping default skills with a gem

One deployment note that pays off later. When you ship a tool as a gem, you want
sensible default skills and the ability for a user to change them. The pattern
`nexo_mail` uses is to ship the skills inside the gem and, on first run, copy them
into the user's config directory only if they are absent. The packaged copy is the
default; editing the copy in the config directory is the override.

The consequence to remember: because seeding is copy-if-absent, editing the
packaged skill in the gem does not reach a user who already ran the tool. Their
copy wins. When you iterate on a shipped skill you have to sync it into their
config directory, or delete their copy so it re-seeds. This is correct behavior,
since you never overwrite a user's edits, but it is surprising the first time.

## What will trip you up

A skill grants no authority. If the model follows the skill and still cannot do
something, the skill described a tool that is not allow-listed. Capabilities come
from `permissions` and `mcp_allow`, never from a skill.

The `skills` macro accumulates across inheritance. A subclass that needs a fresh
set has to reset `@skills` directly.

`ruby_llm-skills` is a soft dependency. `require "nexo"` works without it, and the
first time you touch a skill you get a `MissingDependencyError` if it is not
installed. A missing `SKILL.md` raises `Nexo::Error` naming the path.

Next: [Part 3, adding Gmail and HEY with IMAP and CLI tools](03-tools-imap-cli.md).
