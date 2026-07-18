---
name: inbox_synthesis
description: Build the digest. Read the per-source extraction files from the workspace, merge and de-duplicate them into one picture, roll up the money, order the schedule, narrate the stories and people, and WRITE two files — digest.json (the canonical data) and inbox-digest.md (a short terminal digest). This is where the whole inbox becomes one briefing.
---

# Inbox Synthesis — build the digest

Each source agent has written its extraction to the workspace as JSON
(`apple-mail.json`, `gmail.json`, `hey.json` — whichever sources ran). Your job
is to turn those into ONE picture and write two files with the write tool:

1. `digest.json` — the canonical data (schema below).
2. `inbox-digest.md` — a short markdown digest for the terminal.

Then confirm in one line. Read the source files with your read/glob tools; the
prompt tells you which exist and gives you the run timestamp to stamp in.

## 1. Merge & de-duplicate

Pool every item from every source into one list. Then **de-duplicate the same
message arriving through more than one service** (a newsletter delivered to two
accounts, a thread visible in both Apple Mail and Gmail): treat two items as the
same when their sender and normalized subject match (ignore a leading
`Re:`/`Fwd:`). Keep one, record BOTH services in its `sources` array, and keep
the strongest bucket (`action` > `fyi` > `noise`).

## 2. Roll up the money

From every item carrying a `payment`, build the `finance` block. **Add carefully
— this is the one place a wrong number really hurts.** Sum per currency and
direction; never mix currencies in one total. Keep amounts as plain numbers.
The chart is the biggest outflows (`paid`+`charged`+`due`) in the dominant
currency. See [financial_summary](../financial_summary/SKILL.md).

## 3. Order the schedule

Every item with a `meeting` becomes a `schedule` entry, sorted by `start`
(undated ones last).

## 4. Narrate — stories, people, radar

- **Stories:** group 2+ related messages into a short narrative arc (see the
  story shape below). Don't force them; a lone important message stays in the
  action list.
- **People:** personal mail gets a paragraph, not a line — who they are, what
  they said, whose court the ball is in. This is the part that matters most.
- **Radar / topics:** per-interest "what's going on" briefings (Ruby, Rails,
  photography, any theme with signal) — follow
  [interest_radar](../interest_radar/SKILL.md).

## 5. One message, one surface (dedup across groups)

A message must appear as a **card in exactly one place** — its *strongest* group —
never repeated across sections. Assign each message to the single highest surface
it qualifies for, by this precedence:

1. **Needs action** — it asks the reader to reply / decide / do something.
2. **Story** — it's part of a narrative thread (2+ related messages).
3. **People** — personal mail from someone the reader knows.
4. **Radar** — a newsletter folded into a topic briefing.
5. **FYI** — everything else worth knowing.

So: a personal message that needs a reply goes in **action**, not people; a
newsletter that's part of a story goes in the **story**, not radar; a message
already told inside a story is NOT also listed as its own FYI/action card. Other
sections may still *reference* it by subject (`item_subjects`) — that's a
pointer, not a duplicate card.

**Money and Schedule are different** — they are structured lenses (amounts,
times), not message-card lists. A payment still appears in `finance` and a
meeting in `schedule` even though the underlying message is carded elsewhere.
That's the amount/time view, not a duplicate.

When two messages are genuinely the same thread across sources, you already
merged them in step 1 — keep the strongest bucket and both `sources`.

## digest.json schema

```json
{
  "generated_at": "<the timestamp from the prompt, verbatim>",
  "headline": "one sentence: the shape of the inbox today",
  "sources": ["Gmail", "HEY"],
  "skipped": { "Apple Mail": "reason it was skipped" },
  "counts": { "action": 0, "fyi": 0, "noise": 0, "total": 0 },
  "action": [
    { "sender": "", "sender_email": "", "subject": "", "summary": "",
      "category": "", "received_at": "", "topics": [], "sources": ["Gmail"] }
  ],
  "fyi": [ "...same shape as action..." ],
  "stories": [
    { "title": "", "narrative": "", "bucket": "action|fyi", "tag": "",
      "item_subjects": [] }
  ],
  "people": [
    { "name": "", "relationship": "", "note": "", "item_subjects": [] }
  ],
  "topics": [
    { "topic": "ruby", "label": "Ruby", "headline": "", "bullets": [], "briefing": "", "count": 0 }
  ],
  "finance": {
    "by_currency": { "USD": { "charged": 0, "due": 0, "paid": 0, "refund": 0, "count": 0 } },
    "dominant_currency": "USD",
    "charges": [
      { "merchant": "", "amount": 0, "currency": "USD",
        "direction": "charged|paid|due|refund", "kind": "one_time|subscription",
        "date": "", "subject": "", "source": "" }
    ],
    "subscriptions": [ { "merchant": "", "amount": 0, "currency": "USD" } ],
    "chart": { "currency": "USD", "bars": [ { "label": "", "amount": 0 } ] }
  },
  "schedule": [
    { "title": "", "start": "", "end": "", "location": "", "link": "",
      "rsvp": false, "sender": "", "subject": "", "source": "" }
  ]
}
```

Rules for the data:
- `action`/`fyi` hold the messages of that bucket, most important first. Noise
  stays OUT of these arrays (it's only counted).
- Any array may be empty. Leave a section empty rather than inventing content.
- Never invent a message, person, amount, or event not present in the sources.
- `generated_at` is the timestamp handed to you — don't guess the time.

## 2. inbox-digest.md

Short, most-important-first, for the terminal:

```markdown
# Inbox Digest — <date>

_<headline>_

## Needs action (<n>)
- **<sender>** — <subject>: <the one thing that matters>

## Money
<charged/paid/due one-liner per currency> — <n> subscriptions

## Schedule
- <start> — <title> (<location>) · RSVP

## Radar
- **<Label>** — <headline>

## FYI (<n>)
- **<sender>** — <subject>: <why it matters>

_<n> noise skipped · sources: <…> · <skipped notes>_
```

Omit any section with nothing in it. Keep each line to one sentence.

Write both files once, then confirm in one line.
