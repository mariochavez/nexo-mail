---
name: inbox_synthesis
description: Keep the digest. Build it in full from the per-source extraction files, or update the saved one with only the mail triaged since — merge and de-duplicate into one picture, roll up the money, order the schedule, narrate the stories and people. Write the digest keys to digest.update.json and save them with commit_digest, then write inbox-digest.md (a short terminal digest). This is where the whole inbox becomes one briefing.
---

# Inbox Synthesis — build the digest

Each source agent has extracted its inbox into the workspace as JSON
(`apple-mail.json`, `gmail.json`, `hey.json` — whichever sources ran). Your job
is to keep ONE picture of them, in two files:

1. `digest.json` — the canonical data (schema below). **You never write this file
   directly.** You write the top-level keys you built or changed to
   `digest.update.json` and call `commit_digest`, which replaces exactly those keys
   and keeps every other one as it was.
2. `inbox-digest.md` — a short markdown digest for the terminal, written with the
   write tool.

Then confirm in one line. The prompt gives you the run timestamp to stamp in and
tells you which of two runs this is:

- **FULL build** — there is no digest yet. Read every extraction file the prompt
  names, follow sections 0–5, and put the WHOLE digest in `digest.update.json`.
- **UPDATE** — a digest was saved by an earlier run and most of it is still true.
  Follow [Updating a saved digest](#updating-a-saved-digest) below: you are handed
  only the new mail and you rewrite only the sections it changes.

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

## Updating a saved digest

An update exists so that three new messages cost three messages' worth of work.
Do not re-read the extraction files and do not re-emit sections that did not change.

1. Call `Today`, then `new_items` — it returns every item triaged since the digest
   was saved, each labelled with its `source`. Then read `digest.json` once.
2. **Place each new item**, by the same rules as a full build (sections 1 and 5):
   - Its `id` matches a card already in the digest → the thread moved. Replace that
     card with the new item; do not add a second one. If the move settles it (the
     reply arrived, the bill was paid), it may change bucket or drop out.
   - Otherwise it is new: `noise` only raises `counts.noise`; anything else goes on
     the one surface it is strongest on. A newsletter folds into its topic briefing;
     a message that continues a story extends that story.
3. **Roll the digest forward to today**, even when `new_items` is empty:
   - drop `schedule` entries whose `start` is before `today`;
   - drop cards, charges and briefing material dated before `window_start`. The
     window moves when a new month begins — that run drops a lot, and it is correct.
4. **Money only when money changed.** If a new item carries a `payment`, or the
   window moved, call `SumPayments` ONCE with ONLY the new payments and
   `saved_since` set to `window_start`. The tool adds the charges the digest
   already lists from that date on, so you never re-send them and never go looking
   for them in the extraction files. Replace `finance` with what it returns (same
   rules as section 2). A new payment that is the same transaction as a saved
   charge under a different wording must be left out — the tool only recognises
   exact repeats. With no new payment and no moved window, leave `finance` out.
5. **Write `digest.update.json`** — as little as says what changed. A key you
   leave out is kept untouched, so never include a section just to repeat it.
   - **Lists change one entry at a time, under `edit`.** Do NOT re-write `action`,
     `fyi`, `stories`, `people` or `topics` to add, replace or remove an entry:

     ```json
     "edit": {
       "action": { "put": [ { "id": "…", "…": "the complete card" } ], "drop": ["<id>"] },
       "topics": { "put": [ { "topic": "ruby", "…": "the complete briefing" } ] }
     }
     ```

     `put` replaces the entry with the same identity where it stands, or adds it at
     the top; `drop` removes by identity. The identity is `id` for `action`/`fyi`,
     `title` for `stories`, `name` for `people`, `topic` for `topics`. A card that
     changes bucket is a `drop` from one list and a `put` into the other.
   - Everything else is replaced whole, as a top-level key: always `generated_at`
     (the timestamp from the prompt); `counts` whenever a list or the noise tally
     changed; `headline` when the shape of the inbox did; `sources` / `skipped`
     when the inboxes that ran differ; `finance` and `schedule` when they changed.
   - If nothing changed but the day, the update is just `generated_at` and
     `schedule` if you pruned it.
6. Call `commit_digest`. It returns how long each list is as saved beside your
   `counts`; if they disagree, write a `digest.update.json` holding only the
   corrected `counts` and call it again.
7. Rewrite `inbox-digest.md` to match the digest as it now stands.

An example — a reply in a thread that is already an action card, a new FYI, and a
Ruby newsletter:

```json
{
  "generated_at": "2026-11-28T15:02:00Z",
  "counts": { "action": 11, "fyi": 15, "noise": 55, "total": 81 },
  "edit": {
    "action": { "put": [ { "id": "1288908389", "sender": "…", "subject": "…", "summary": "where the thread stands now", "…": "…" } ] },
    "fyi": { "put": [ { "id": "1290400001", "sender": "…", "subject": "…", "summary": "…", "…": "…" } ] },
    "topics": { "put": [ { "topic": "ruby", "label": "Ruby", "headline": "…", "bullets": ["…"], "briefing": "…", "count": 7 } ] }
  }
}
```

`stories`, `people`, `finance` and `schedule` are absent because they did not change.

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

On a full build `digest.update.json` holds all of this; on an update, only the
top-level keys that changed.

```json
{
  "generated_at": "<the timestamp from the prompt, verbatim>",
  "headline": "one sentence: the shape of the inbox today",
  "sources": ["Gmail", "HEY"],
  "skipped": { "Apple Mail": "reason it was skipped" },
  "counts": { "action": 0, "fyi": 0, "noise": 0, "total": 0 },
  "action": [
    { "id": "", "sender": "", "sender_email": "", "subject": "", "summary": "",
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
- `id` is the extraction item's own `id`, carried through unchanged. It is how a
  later update recognises that a thread it is handed is already a card.

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

Write `digest.update.json`, call `commit_digest`, write `inbox-digest.md`, then
confirm in one line.
