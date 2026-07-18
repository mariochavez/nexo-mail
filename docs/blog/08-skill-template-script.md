---
title: "A skill that ships a template and a script"
date: 2026-07-17
category: desarrollo
tags: [ruby, ai, nexo, skills, shell, security]
series: "Building an email agent with Nexo"
part: 8
---

# A skill that ships a template and a script

The last output the tool needs is a dashboard: a self-contained `dashboard.html` a
person can open and read. I tried having an agent write the HTML directly from the
digest, and it worked, but every run produced a slightly different page. Spacing
moved, a section rendered differently, sometimes a small model dropped a piece. For
a daily briefing I wanted the design to be identical every time.

So the dashboard is not written by the model. It is a fixed template plus a render
script, both shipped with a skill, and the agent's job is to run the script over
the digest. That decision is simple to state and has one real consequence: running
a script needs a shell, and up to now no agent in this tool has had one. This post
builds the dashboard step and, more importantly, works through how to open the
read-only guarantee for exactly one agent without giving anything away.

## Why a template and a script, not model-authored HTML

A skill has been instructions only so far. But a skill package is a directory, and
it can carry more than `SKILL.md`. The `dashboard_designer` skill ships two assets
alongside its instructions:

```
dashboard_designer/
├── SKILL.md
├── assets/dashboard-template.html    # the fixed design: CSS + a JS renderer
└── scripts/render_dashboard.rb        # injects digest.json into the template
```

The template is the whole design, written once. It renders the page on the client
from a JSON blob embedded in it. The script's only job is to put the run's
`digest.json` into that blob and write the result. Because the design lives in a
fixed file and the script is deterministic, every run produces a byte-identical
page. To change the look, I edit the template. The model never authors HTML.

This is also the safe shape. The untrusted email text goes into the page as data
that JavaScript renders with `textContent`, never as markup and never as code. The
one place the data meets the document is the JSON blob, and the script escapes it.

## The render script

The script reads the digest, escapes it, and substitutes it into the template:

```ruby
require "json"

digest   = File.read(ARGV[0])   # digest.json
template = File.read(ARGV[1])   # dashboard-template.html

data = JSON.parse(digest)       # parse to validate, re-serialize compactly

# ascii_only escapes every non-ASCII char to \uXXXX, so accents and arrows survive
# whatever charset the browser guesses. Then escape < > & so the blob cannot break
# out of the <script type="application/json"> it lives in.
safe = JSON.generate(data, ascii_only: true).gsub(/[<>&]/) { |c| format("\\u%04x", c.ord) }

File.write(ARGV[3], template.sub("__DIGEST_JSON__", safe))
```

The escaping is the security-critical line, and it is done here, in Ruby, not left
to the model. Neutralizing `<` defeats a `</script>` breakout, which is the only
way untrusted text embedded in a script tag can escape. `ascii_only` is what fixes
the mojibake you would otherwise get on `México` or an arrow when the page opens
from a file with no declared charset. The template itself carries a
`<meta charset="utf-8">` as a second belt.

## The step that needs a shell

To run that script, the agent needs the shell tool. Every agent so far has been
read-only plus write, which does not attach a shell. Running a script is a real
capability, so the agent that does it, the Publisher, is granted one:

```ruby
class Publisher < SourceAgent
  @skills = %i[dashboard_designer]

  # Read, glob, write, and shell. This is the only agent in the tool with a shell.
  permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write shell])

  instructions <<~TXT
    You render the dashboard by running the command the prompt gives you with the
    shell tool. You do not hand-write HTML. Run it exactly, then confirm in one line.
  TXT
end
```

This is a genuine relaxation of the tool's core property, so it is worth being
honest about it rather than burying it. An agent driven by a language model now has
a shell inside its sandbox. The question is not whether that is a capability, it
is, the question is how to keep it narrow.

## Opening the guarantee narrowly

The mitigations are what make this acceptable, and they are all specific.

The Publisher attaches no mail tools. It has no MCP server, no IMAP tool, no CLI
wrapper. It cannot reach any inbox. It reads only the `digest.json` that an earlier
stage already produced, which is derived data, not raw mail.

The script it runs is developer-authored and shipped with the skill. The model does
not write the script or choose what it does; it runs a fixed command against fixed
files.

The shell runs inside the `:local` sandbox with the narrowed environment from
[Part 6](06-sandbox-permissions.md), seeing only `PATH`, `HOME`, and `LANG`.

And it is the only agent with a shell. Every mail-reading agent stays read-only
with no shell. You can check this: asking a source agent's permissions to authorize
shell raises; asking the Publisher's does not.

The rule I would take from this is the general one. When you have to open the
sandbox, open it for one agent, for one job, and write down why. A blanket
escalation to `:auto` would have been one line shorter and far worse. The narrow
version is auditable: anyone reading the code can see exactly which agent got what,
and confirm nothing else did.

## Pulling the assets from config

The Publisher runs the script, but where the script and template come from is
configuration, not a hardcoded path. The tool exposes a `[dashboard]` block:

```toml
[dashboard]
ruby     = "/path/to/ruby"           # the interpreter to run the script with
template = "…/dashboard-template.html"
renderer = "…/render_dashboard.rb"
```

The defaults point at the skill's bundled assets, so it works out of the box. The
workflow reads those settings and hands the Publisher the exact command:

```ruby
def publisher_prompt
  "Run exactly, with the shell tool:\n\n" \
    "  #{Config.dashboard_ruby} #{Config.dashboard_renderer.inspect} " \
    "digest.json #{Config.dashboard_template.inspect} dashboard.html"
end
```

Repointing `template` at your own HTML restyles the dashboard without touching the
gem, and pinning `ruby` to an absolute interpreter matters because the sandbox
shell runs with a narrowed `PATH`, so a version-managed `ruby` may not resolve
otherwise.

## The Nexo-native alternative

Nexo has a built-in way to render a deliverable from a template, `artifact(name,
from:, locals:)`, which renders a trusted ERB template with the data you pass and
records it on the run. It is the shorter path for the common case, and I want to
name it because it is the idiomatic Nexo tool here.

I did not use it, for two reasons specific to this output. ERB is code, and Nexo is
explicit that an `artifact(from:)` template must be a trusted developer file, never
anything derived from model output, because ERB executes Ruby. A client-side
template that renders untrusted email text through `textContent` keeps that text
out of any code path entirely. And I wanted the render to be a script an agent
runs, so the dashboard generation stays on the agent side like everything else,
rather than in the library. For a deliverable built from fully trusted data, reach
for `artifact(from:)` first; the script approach is what I wanted for untrusted
content plus agent-run generation.

## Where this leaves us

The tool now produces the full briefing: `digest.json`, `inbox-digest.md`, and a
consistent `dashboard.html`, with exactly one agent holding a narrowly scoped
shell. The pieces that remain are about acting rather than reading, and about
shipping. The next post looks at durable workflows and human approval, the path a
read-only tool would take if it ever grew a safe write action. The last one is
packaging: the CLI, the config layer, and moving the same workflow into a Rails app.

## What will trip you up

The escaping belongs in the script, not the model. Escape the JSON blob in code,
where it is deterministic. A `</script>` in a subject line is a real breakout if
you skip it, and you cannot rely on a model to escape reliably.

Declare the charset and escape non-ASCII. Use `ascii_only: true` when generating the
blob and put `<meta charset="utf-8">` in the template, or accents render as
mojibake when the file opens from disk.

The sandbox shell has a narrowed PATH. A version-managed `ruby` may not be found.
Pin the interpreter path in config.

Grant the shell to one agent, and say why. Do not reach for `:auto`. Add `:shell`
to a single agent that has no mail tools and reads only derived data, and leave a
comment explaining the scope, so the escalation stays auditable.

Next: [Part 9, durable workflows and human approval](09-durable-approval.md).
