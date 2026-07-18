---
title: "Adding Gmail and HEY with custom tools"
date: 2026-07-17
category: desarrollo
tags: [ruby, ai, nexo, ruby_llm, imap, cli]
series: "Building an email agent with Nexo"
part: 3
---

# Adding Gmail and HEY with custom tools

Apple Mail was reachable over MCP, so [Part 1](01-first-agent-mcp.md) attached it
with the `mcp` macro and never wrote a line of integration code. Gmail and HEY are
different. Gmail I want to read over IMAP with an app password, without OAuth or a
Google SDK. HEY has a command line client and no public API. Neither speaks MCP.

For those, Nexo uses its other tool shape: a plain
[`RubyLLM::Tool`](https://rubyllm.com/tools). You write a small Ruby class that
does the work and returns a result, attach it to the agent, and the model calls it
the same way it calls an MCP tool. Everything the harness gives you, the sandbox
and permission seams, still applies.

This post adds Gmail and HEY as custom tools, and introduces a base agent plus a
single *data-driven* source, so a tool-based inbox is a descriptor you add to a
table, not a class you write.

## A custom tool is a small Ruby class

A `RubyLLM::Tool` subclass declares a description, its parameters, and an `execute`
method. Here is the Gmail tool that lists recent inbox messages:

```ruby
module NexoMail
  module Tools
    module GmailImap
      class List < RubyLLM::Tool
        description "List recent Gmail INBOX messages (uid, from, subject, date) as JSON. Read-only."
        param :only_unread, type: :boolean, required: false, desc: "Only unread messages (default true)"
        param :limit,       type: :integer, required: false, desc: "Max messages, newest first (default 20)"
        param :since_days,  type: :integer, required: false, desc: "Only messages newer than N days"

        def execute(only_unread: true, limit: 20, since_days: nil)
          GmailImap.with_inbox do |imap|
            criteria = []
            criteria << "UNSEEN" if only_unread
            criteria = ["ALL"] if criteria.empty?

            uids = imap.uid_search(criteria).last(limit.to_i)
            rows = imap.uid_fetch(uids, %w[ENVELOPE INTERNALDATE FLAGS]).map do |d|
              env = d.attr["ENVELOPE"]
              {
                uid:     d.attr["UID"],
                from:    GmailImap.format_address(env&.from&.first),
                subject: env&.subject,
                date:    (env&.date || d.attr["INTERNALDATE"]).to_s
              }
            end
            {messages: rows.reverse}
          end
        end
      end
    end
  end
end
```

The `description` and the `param` lines are what the model sees; write them the way
you would write API docs, because that is exactly how they are used. `execute`
returns a Ruby hash, which `ruby_llm` serializes and hands back to the model as the
tool result.

Two details make this read only. The mailbox is opened with IMAP `EXAMINE`, which
is a read-only select, so the server itself refuses any change. And messages are
fetched with `BODY.PEEK`, which reads without setting the `\Seen` flag, so
triaging your inbox does not silently mark everything as read. The read-only
guarantee here is a property of how the IMAP session is opened, not something the
prompt asks for. This is the IMAP equivalent of the MCP allow-list from Part 1.

There is a second Gmail tool, `GmailImap::Read`, that fetches one message body by
uid for the ambiguous cases. I am leaving it out for space; it follows the same
shape.

## Wrapping a CLI safely

HEY has no API, but it has a `hey` command line client that can print JSON. The
temptation is to shell out with a string. Do not. A shell string is an injection
surface the moment any part of the command comes from model output or user input.

The tools run the CLI as an argv array through `Open3`, so nothing is ever passed
to a shell to interpret:

```ruby
module NexoMail
  module Tools
    module CliReader
      module_function

      def json(*argv)
        out, err, status = Open3.capture3(*argv)   # argv array, never a shell string
        unless status.success?
          return {error: "#{argv.first} exited #{status.exitstatus}: #{err.strip[0, 300]}"}
        end

        begin
          JSON.parse(out)
        rescue JSON::ParserError
          {raw: out.strip[0, 4000]}
        end
      rescue Errno::ENOENT
        {error: "`#{argv.first}` not found on PATH, is it installed and authenticated?"}
      end
    end
  end
end
```

`Open3.capture3(*argv)` passes each element as a separate argument to the program.
There is no shell, so no quoting, globbing, or `;` chaining is possible. The
subcommands are hardcoded in the tools; the model chooses a box name from a fixed
set, not an arbitrary command.

Notice the return values. A non-zero exit becomes `{error: ...}`, and unparseable
output becomes `{raw: ...}`. The tool never raises. This is a convention worth
adopting for every tool you write: a tool that fails returns an error hash, which
the model receives as recoverable context and can adapt to. A tool that raises
crashes the whole loop. Nexo's own built-in tools follow the same rule, and so do
denied permissions.

The HEY box tool builds on `CliReader`:

```ruby
class HeyBox < RubyLLM::Tool
  description <<~DESC.strip
    List postings from one HEY box as JSON (sender, subject, id). Read-only.
    Call once per box: "imbox" is mail from people, "feed" is newsletters,
    "papertrail" is receipts and confirmations.
  DESC
  param :box, type: :string, required: false, desc: "Which box (default imbox)"

  BOXES = %w[imbox feed papertrail].freeze

  def execute(box: "imbox")
    name = BOXES.include?(box.to_s) ? box.to_s : "imbox"
    CliReader.json("hey", "box", name, "--json")
  end
end
```

HEY sorts mail into three boxes, and each one means something different for
triage. The Imbox is people and things that matter. The Feed is newsletters. The
Paper Trail is receipts. The tool exposes the box as a parameter and validates it
against a fixed list, so the agent can pull all three and treat each one
differently, but it cannot ask for an arbitrary box.

## Attaching custom tools

MCP servers attach with the `mcp` macro. Custom `RubyLLM::Tool` classes attach a
different way: you override the agent's `#chat` method, call `super` to get the
chat Nexo built, and add your tools to it.

```ruby
def chat(base: nil)
  chat = super
  chat.with_tools(Tools::GmailImap::List.new, Tools::GmailImap::Read.new)
  chat
end
```

`super` gives you the fully wired chat, with the instructions, the skills, and the
built-in sandbox tools already applied. `with_tools` is additive, so your tools sit
alongside those. This is the seam Nexo leaves open for anything the macros do not
cover.

## One base agent, and a source you configure with data

Apple Mail, Gmail, and HEY differ only in how they reach mail. The model, the
permission mode, the skills, and the instructions are identical. Repeating them in
three classes would be a maintenance problem, so the shared configuration lives in
a base class:

```ruby
class SourceAgent < Nexo::Agent
  sandbox     :local
  permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write])
  skills      :email_triage, :financial_summary, :interest_radar

  instructions <<~TXT
    You triage one email inbox using the attached skills and write the result as a
    JSON array with the write tool. Read only: never send, delete, or modify mail.
  TXT

  # The two per-source inputs #chat wires. Instance readers, defaulting to
  # class-level values — so a data-driven source can override them per instance.
  def source_tools = self.class.source_tools
  def prompt_key   = self.class.prompt_key
  def self.source_tools = []
  def self.prompt_key   = nil

  def chat(base: nil)
    chat  = super
    tools = source_tools.map(&:new)
    chat.with_tools(*tools) unless tools.empty?
    chat
  end
end
```

Now look at what actually differs between Gmail and HEY: a list of tool classes
and a prompt key. That is *data*, not behavior. So instead of a class per source,
there is one `EmailSource` that reads those two things from a descriptor handed to
it at construction:

```ruby
class EmailSource < SourceAgent
  def initialize(descriptor:, cwd:)
    @descriptor = descriptor
    super(cwd: cwd)
  end

  def source_tools = @descriptor.tools
  def prompt_key   = @descriptor.prompt_key
end
```

The descriptors live in a small catalog. Each is a value object carrying
everything a tool-based source needs — its display name, the file it writes, its
tools, a prompt key, and an availability check — and it knows how to build its
agent:

```ruby
module NexoMail
  module Sources
    Descriptor = Struct.new(:name, :file, :prompt_key, :tools, :availability) do
      def available? = availability.call
      def build(cwd:) = Agents::EmailSource.new(descriptor: self, cwd: cwd)
    end

    def self.all
      [
        Descriptor.new(
          name: "Gmail", file: "gmail.json", prompt_key: "gmail",
          tools: [Tools::GmailImap::List, Tools::GmailImap::Read],
          availability: -> { "Gmail not configured" if Config.gmail_address.to_s.empty? }
        ),
        Descriptor.new(
          name: "HEY", file: "hey.json", prompt_key: "hey",
          tools: [Tools::HeyBox, Tools::HeyThread],
          availability: -> { "hey not on PATH" unless Agents::EmailSource.command?("hey") }
        )
      ]
    end
  end
end
```

Adding another IMAP-or-CLI inbox later is a new row in this table, not a new class.
(The availability lambdas are abbreviated here; the real ones check credentials and
CLI auth state.)

Apple Mail is the one exception, and it is an instructive one. It reaches mail
through the `mcp` macro — and that macro is *class-level*: Nexo stores it on the
class, so it cannot vary per instance from a descriptor. So Apple Mail keeps its
own small class:

```ruby
class AppleMailSource < SourceAgent
  permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write],
                                    mcp_allow: NexoMail::MAIL_READ_TOOLS)
  mcp :mail, transport: :stdio, command: "apple-mail-mcp"
  def self.prompt_key = "apple_mail"
end
```

But I still want the *catalog* to list all three inboxes, so the workflow (next
post) can walk one uniform list. So the catalog carries a second, tiny descriptor
for Apple Mail that answers the same `available?`/`build` interface but builds its
own class:

```ruby
AppleDescriptor = Struct.new(:name, :file) do
  def available? = Agents::AppleMailSource.availability
  def build(cwd:) = Agents::AppleMailSource.new(cwd: cwd)
end

# ...and Sources.all lists all three: the Apple descriptor, plus the Gmail and
# HEY descriptors above.
```

Two shapes, then. Tool-based sources are *data* behind a single `EmailSource`; the
one MCP source stays a class — but both are reached through the same descriptor
interface, so the catalog is one flat list. Both inherit the base too: Nexo's
`inherited` hook (from [Part 2](02-skills.md)) copies the parent's macro
configuration down, duplicating arrays and hashes so a child never mutates the
parent's, and both share the same triage behavior.

I have granted `:write` here in addition to read and glob, because the agents will
soon write their output into a workspace instead of returning it as text. What that
`:local` sandbox is and how its writes are fenced is the subject of a later post;
for now, `:write` lets the agent call the built-in `WriteFile` tool.

## Provider neutrality is not an accident

It is worth pointing out what this buys. Gmail is read over plain IMAP, not the
Gmail API, so there is no OAuth dance and no Google client gem. HEY is read through
its own CLI. Apple Mail is read through a local MCP server. None of the agent code
is tied to a vendor. If Gmail changed its API tomorrow, the IMAP tool would not
care. This is the same property MCP gave us in Part 1, applied to services that do
not offer MCP at all: every source converges to the same abstraction, a tool the
agent can call.

## Where this leaves us

There are now three inboxes covered — Gmail and HEY through one data-driven
`EmailSource`, Apple Mail through its own class — each reading a real inbox read
only, all sharing one base. But they are still separate agents I would run by hand,
and there is no single result. Next I wrap them in a workflow, which walks the
source catalog, runs each one, records what happened in an inspectable event log,
and produces one digest, while staying resilient when a source is missing or fails.

## What will trip you up

Write your tool descriptions and parameter docs carefully. They are the only thing
the model knows about the tool. A vague description is the usual reason a model
calls a tool wrong or not at all.

Return an error hash, never raise. `{error: ...}` is recoverable context the model
can work with. A raised exception ends the run. Wrap external calls and IO so a
missing binary or a bad response comes back as an error the model can see.

Run CLIs as argv arrays. `Open3.capture3(*argv)` with separate arguments has no
shell and no injection surface. Never interpolate model output into a command
string.

Attach custom tools by overriding `#chat` and calling `super` first. If you build
the chat yourself instead of calling `super`, you lose the instructions, skills,
and built-in tools Nexo assembled.

Next: [Part 4, wrapping the sources in a workflow](04-workflows.md).
