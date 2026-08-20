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

## 0. First: what day is it, and what window are we covering

**Call the `Today` tool before you read anything else.** Then set the window:

> **window_start = the 15th of `previous_month`.  window_end = `today`.**

The current month plus the tail of the previous one. Nothing outside it belongs in
the digest — not in action/fyi, not in the money totals, not in the schedule, not in
the radar. The source agents were told the same rule, so anything older that still
reaches you is a mistake to drop, not data to report.

Comparing ISO dates is plain string order; you do not need to compute anything
beyond the window itself.

## 1. Merge & de-duplicate

Pool every item from every source into one list. Then **de-duplicate the same
message arriving through more than one service** (a newsletter delivered to two
accounts, a thread visible in both Apple Mail and Gmail): treat two items as the
same when their sender and normalized subject match (ignore a leading
`Re:`/`Fwd:`). Keep one, record BOTH services in its `sources` array, and keep
the strongest bucket (`action` > `fyi` > `noise`).

## 2. Roll up the money — per currency, with the tool

Gather every item carrying a `payment` **whose date is inside the window**, and pass
them all in ONE call to `SumPayments`. Filtering is your job — the tool has no idea
what today is and will faithfully add up whatever you hand it.

Build `finance` from what it returns. Its `by_currency` is already the shape you
want: **each currency is a self-contained block holding its own `charges` list and
its own totals** (`charged`/`paid`/`due`/`refund`, plus `out`, `net`, `count`,
`subscriptions`). Copy each block through as-is.

**Do not add the numbers yourself and do not re-derive the totals afterwards.** When
the totals and the list were produced separately they drifted: a real run reported
USD `charged: 289.00` against its own list summing to 269.00.

- **Keep currencies apart everywhere** — totals, lists and the terminal digest. There
  is no exchange rate here, and the tool will never invent one. Two honest totals
  beat one merged fiction. Order currencies by the size of `out`, biggest first.
- The chart is the biggest outflows (`out`) within a single currency — never across.
- If the tool returns `needs_direction` or `ignored`, those payments were NOT counted.
  Fix the `direction`/`amount` and call again, or leave them out and say so — never
  fold them into a total by hand.

See [financial_summary](../financial_summary/SKILL.md).

## 3. Order the schedule — upcoming only

Every item with a `meeting` becomes a `schedule` entry, sorted by `start` (undated
ones last).

**Drop meetings that have already happened.** A schedule is for what is still ahead:
keep an entry only when its `start` is on or after `today` (from the `Today` tool),
or when it has no date at all.

This is not hypothetical — a run generated on 2026-08-20 published a schedule of
2026-06-18, 2026-07-17 and 2026-07-23, every one already past. If nothing is
upcoming, omit the schedule section entirely rather than filling it with history.

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

## Counts must equal the lists they describe

`counts.action` MUST equal the number of entries in `action`, and `counts.fyi` MUST
equal the number in `fyi`. Emit the array first, then count it — never state a count
you did not derive from the list you actually wrote.

`counts.noise` is the exception: noise items are not emitted as an array, so it is a
plain tally.

`counts.total` MUST equal `action + fyi + noise` exactly. It is the count AFTER
de-duplication — not the number of items you read out of the source files. If you
merged two copies of one newsletter into a single item, the total drops by one.

A real run reported `counts: {action: 6, fyi: 8}` while emitting 3 entries in each —
the dashboard then renders "Needs action (6)" above three cards. If an item is worth
counting as action, emit it; if it is not worth emitting, do not count it.

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
    "currencies": ["MXN", "USD"],
    "by_currency": {
      "USD": {
        "charged": 0, "paid": 0, "due": 0, "refund": 0,
        "out": 0, "net": 0, "count": 0, "subscriptions": 0,
        "charges": [
          { "merchant": "", "amount": 0, "currency": "USD",
            "direction": "charged|paid|due|refund", "kind": "one_time|subscription",
            "date": "", "subject": "", "source": "" }
        ]
      }
    },
    "dominant_currency": "USD",
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
### <CURRENCY>
<charged/paid/due/refund one-liner> — <n> subscriptions
<repeat one block per currency, biggest `out` first; never merge currencies>

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
