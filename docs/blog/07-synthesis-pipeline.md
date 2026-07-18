---
title: "Merging the sources into one digest"
date: 2026-07-17
category: desarrollo
tags: [ruby, ai, nexo, workflows, skills]
series: "Building an email agent with Nexo"
part: 7
---

# Merging the sources into one digest

After [Part 6](06-sandbox-permissions.md) the workflow produces three JSON files,
one per source, each a list of classified items. That is not a briefing. The same
newsletter can arrive in two accounts, the payments are scattered across the files,
the meetings are not in order, and there is no narrative tying anything together. I
want one `digest.json` that is the whole picture, and a short `inbox-digest.md` for
the terminal.

The obvious way to build that is a pile of Ruby: parse the three files, dedupe,
group, sum the money, sort the schedule, write the markdown. I did not do it that
way, and this post is about why. The merging and narration is judgment, and in this
design judgment belongs to an agent and a skill, not to the library. The Ruby stays
thin.

## One more agent, no mail tools

The synthesis step is another agent. It reads the per-source files the source
agents wrote, and it writes the two outputs. It reaches no mail, so it attaches no
mail tools, and it uses a different set of skills than the extraction agents:

```ruby
class Synthesize < SourceAgent
  # Reset the extraction skills inherited from SourceAgent; this agent narrates.
  @skills = %i[inbox_synthesis financial_summary interest_radar]

  instructions <<~TXT
    You build the digest from the per-source extraction files in the workspace.
    Read the source JSON files, merge and de-duplicate the items, roll up the money
    per currency, order the schedule, and narrate stories, people, and topic
    briefings. Write two files: digest.json (the canonical data) and
    inbox-digest.md (a short terminal digest). You do not read mail.
  TXT
end
```

This is where the inheritance detail from [Part 2](02-skills.md) matters in
practice. `Synthesize` inherits from `SourceAgent`, so it would inherit the
extraction skills, and those would fight its job. Because the `skills` macro
accumulates rather than replaces, resetting means assigning the class variable
directly with `@skills = ...`. Now the synthesis agent carries only the skills
about synthesizing.

Everything else it inherits: the model, the `:local` sandbox, and the read-only
plus write permissions. It reads the source files and writes two new ones, all
inside the same fenced workspace.

## The judgment lives in the skill

The interesting content is not in the Ruby above. It is in the `inbox_synthesis`
skill, which is where the actual rules live. That skill specifies how to merge and
dedupe, and it does dedupe on two axes.

The first is cross-source. The same message can land in two accounts, so identical
sender and subject across files collapse to one item that records both sources. The
second is cross-group. A single message should appear in only its strongest place,
so a message that belongs to a narrative story is not also listed on its own, and a
newsletter folded into a topic briefing is not repeated in the general list. The
skill defines the precedence and the model applies it.

The skill also defines the money roll-up, the schedule ordering, and the shape of
the stories, the per-person notes, and the topic briefings. And it defines the
exact JSON contract for `digest.json`, down to the field names, because everything
downstream, including the dashboard in the next post, is built from those fields.

None of that is Ruby. If I want to change how dedupe works, or add a category, or
change what counts as a story, I edit the skill. The library does not move.

## Wiring it into the workflow

The workflow gains one more stage after the sources. It hands the synthesis agent
the names of the files that were produced and a timestamp to stamp into the output:

```ruby
def call(payload)
  available, skipped = partition_sources
  skipped.each { |name, reason| emit(:source_skipped, source: name, reason: reason) }

  produced = fan_out_sources(available)
  return {sources: [], skipped: skipped} if produced.empty?

  drive_agent(Agents::Synthesize, "synthesis", synthesis_prompt(produced, payload))

  {sources: produced.keys, skipped: skipped}
end
```

`drive_agent` is the small helper from Part 4 that instantiates an agent, prompts
it, forwards its events into the run log, and closes it. The synthesis prompt just
tells the agent which files exist and what timestamp to use. The workflow does not
read the files, does not parse JSON, and does not decide anything about the
content. It sequences the stages and records what happened.

## Why keep the Ruby this thin

This is a deliberate design choice, and it is worth stating plainly because it runs
against the instinct to do the "real work" in code. The rule I settled on is that
Ruby provides tools and orchestration, and the agents with their skills do the
work. The library reads no mail, parses no model output into decisions, and makes
no classification. Every piece of judgment, from what counts as Action to how to
dedupe to how to phrase a story, lives in a skill.

The payoff is that behavior is tuned by editing Markdown, by a person who does not
need to touch Ruby, without a redeploy. The cost is honesty about one thing: the
money totals are summed by the model, not by Ruby. On a small local model,
arithmetic can drift. If you want the totals guaranteed correct, the clean move
that stays within this design is a small `compute_totals` tool the synthesis agent
calls, so the summing is deterministic while the decision to call it stays with the
agent. In `nexo_mail` I left the arithmetic in the model and documented the
trade-off; the point is that the seam for fixing it is a tool, not a rewrite.

## A word on structured output

The synthesis agent writes `digest.json` by following the JSON shape the skill
describes, and the Ruby parses it tolerantly, dropping malformed entries rather
than crashing. That is a pragmatic choice for small local models. If you want the
output validated against a real schema, Nexo does not provide that, and it does not
need to: structured output lives in `ruby_llm-schema`, and you apply it to the chat
Nexo built with `chat.with_schema`. Either way the contract is written once, in the
skill, and both the synthesis output and the dashboard depend on it.

## Where this leaves us

There is now a single `digest.json` that is the whole briefing, plus a markdown
version for the terminal, produced by an agent following a skill, with the library
doing nothing but orchestration. The last output missing is the one a person
actually wants to look at: a dashboard. That is the next post, and it introduces a
new capability for a skill, shipping its own template and a script, which forces a
careful, narrow decision about the read-only guarantee.

## What will trip you up

Reset skills with the class variable, not the macro. A synthesis agent that
inherits an extraction base will carry the extraction skills unless you assign
`@skills` directly, because the macro only accumulates.

Keep the JSON contract in one place. The skill defines the field names, and both
the synthesis output and everything downstream depend on them. If you rename a
field, do it in the skill and update the consumers, or the dashboard silently loses
a section.

Be honest about model arithmetic. If exact numbers matter, do not sum them in the
model. Give the agent a deterministic tool to call. This keeps the thin-Ruby design
while making the totals trustworthy.

The digest is only as good as the extraction. Synthesis cannot recover a field a
source agent never captured. When a section looks thin, the fix is usually in the
extraction skills, not the synthesis one.

Next: [Part 8, a skill that ships a template and a script](08-skill-template-script.md).
