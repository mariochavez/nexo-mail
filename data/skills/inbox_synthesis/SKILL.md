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

## 2. The money picture — from the tool

Call `money_report` ONCE with:

- `since` = `month_start`, `until` = `today` — money is read by **calendar month**;
- `compare_since` = `previous_month_start`, `compare_until` = the day before
  `month_start` — last month's totals, for comparison;
- `bills_since` = `days_ago 90` — an unpaid bill from last month is still unpaid.

**Do not write `finance`.** The tool builds the section from every payment on
record and `commit_digest` saves it. You never gather payments, add numbers or
copy the result. See [financial_summary](../financial_summary/SKILL.md).

What you do with what it returns:

- **Match bills to payments.** If `open_bills` lists a bill and the rows show a
  later payment that plainly settled it, call again with `settled`. If two rows are
  one transaction under different wording, call again with `skip`. At most one
  follow-up call.
- **Say what matters** in the headline and `inbox-digest.md`: overdue or soon-due
  bills first, then income received, then what was spent — per currency, never
  merged.
- **`recurring_missing`** lists merchants billed in two or more earlier months and
  not yet this month. Mention one only when its usual day has already passed;
  early in a month most of that list is simply not due yet.
- An open bill that is overdue or due within 7 days also gets an `action` card.

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

## 4b. Lanes — each kind of mail has its own place and its own lifetime

Every extraction item carries a `lane`. It decides WHERE in the digest the item
can appear and HOW LONG it stays. The single window of section 0 still bounds the
money totals; everything else follows its lane. Dates come from `Today`'s
`days_ago` — never subtract days yourself.

| `lane` | Where it goes | Stays |
|---|---|---|
| `conversation` | `action` when it needs the reader, else `people` / `stories` / `fyi` | While the thread is open: an `action` card stays until a later message settles it. Other cards, `days_ago 30`. |
| `money` | `finance` (section 2). Also an `action` card when a bill is due or a payment failed. | The section 0 window. |
| `dev` | `dev` — ONE entry per `ref`, however many notifications arrived and through however many inboxes. Never an `action` or `fyi` card. | Open things stay. Merged, closed, released or passing: `days_ago 7` from the last activity, then gone. |
| `reading` | `topics` (the radar). Never an `fyi` card. | The radar briefs the last 7 days (`days_ago 7`); an issue older than that no longer feeds a briefing. |
| `opportunity` | `opportunities`, soonest deadline first. | Until its `deadline` (or `starts`, when there is no deadline) is before `today`. Undated: `days_ago 30`. |
| `jobs` | `jobs`, newest first. | `days_ago 14`. |
| `ephemeral` | Nowhere. It is counted in `counts.ephemeral` and nothing else. | — |

**`dev` entries.** Group every `dev`-lane item by its `dev.ref` and write one entry:
the latest `state`, the newest `updated_at`, how many notifications it gathered
(`events`), `waiting_on_me` true when any unanswered one says so, and a `summary`
of where it stands now — not a list of what happened. Order: `waiting_on_me` first,
then open things by `updated_at`, then finished ones. **A `dev` item is never an
`action` or `fyi` card**, even when it waits on the reader: the `dev` list leads
with those and the dashboard flags them, so a card would only say it twice. Count
them in the headline ("three reviews waiting"), not in `counts.action`.

**A `meeting` always goes to `schedule`**, whatever its lane — an invitation to a
gallery opening with a time and an RSVP is an appointment, not a deadline. An item
that is in `schedule` is not also listed in `opportunities`.

**Counts.** `counts.noise` is the noise that is NOT ephemeral; `counts.ephemeral` is
the ephemeral tally. `counts.total` = `action + fyi + noise + ephemeral`.

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
   - Otherwise it is new, and its `lane` says where it can go (section 4b):
     `ephemeral` only raises `counts.ephemeral`; other `noise` only raises
     `counts.noise`; a `dev` item updates the entry for its `ref` (or adds one); a
     `reading` item folds into its topic briefing; an `opportunity` or `jobs` item
     joins that list; a message that continues a story extends that story.
3. **Roll the digest forward to today**, even when `new_items` is empty:
   - drop `schedule` entries whose `start` is before `today`;
   - drop charges dated before `window_start`. The window moves when a new month
     begins — that run drops a lot, and it is correct;
   - drop whatever has outlived its lane (section 4b): finished `dev` entries a
     week old, `opportunities` whose date has passed, `jobs` older than 14 days,
     `fyi` cards older than 30. An `action` card is never dropped for age alone.
4. **Money only when money changed.** If a new item carries a `payment`, or the
   month changed since the digest was built, call `money_report` exactly as in
   section 2. It re-reads the record and replaces `finance` on commit — you send no
   payments and write no `finance` key. Otherwise do not call it, and `finance`
   stays as it is.
5. **Write `digest.update.json`** — as little as says what changed. A key you
   leave out is kept untouched, so never include a section just to repeat it.
   - **Lists change one entry at a time, under `edit`.** Do NOT re-write `action`,
     `fyi`, `stories`, `people`, `topics`, `dev`, `opportunities` or `jobs` to add,
     replace or remove an entry:

     ```json
     "edit": {
       "action": { "put": [ { "id": "…", "…": "the complete card" } ], "drop": ["<id>"] },
       "topics": { "put": [ { "topic": "ruby", "…": "the complete briefing" } ] }
     }
     ```

     `put` replaces the entry with the same identity where it stands, or adds it at
     the top; `drop` removes by identity. The identity is `id` for `action`/`fyi`,
     `title` for `stories`, `name` for `people`, `topic` for `topics`, `ref` for
     `dev`, `id` for `opportunities` and `jobs`. A card that
     changes bucket is a `drop` from one list and a `put` into the other.
   - Everything else is replaced whole, as a top-level key: always `generated_at`
     (the timestamp from the prompt); `counts` whenever a list or the noise tally
     changed; `headline` when the shape of the inbox did; `sources` / `skipped`
     when the inboxes that ran differ; `schedule` when it changed. Never `finance`:
     `money_report` saves it.
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

`counts.total` MUST equal `action + fyi + noise + ephemeral` exactly. It is the count AFTER
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
  "counts": { "action": 0, "fyi": 0, "noise": 0, "ephemeral": 0, "total": 0 },
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
  "finance": "— built and saved by money_report; never written by you —",
  "schedule": [
    { "title": "", "start": "", "end": "", "location": "", "link": "",
      "rsvp": false, "sender": "", "subject": "", "source": "" }
  ],
  "dev": [
    { "ref": "owner/repo#123", "kind": "pr", "title": "", "state": "open",
      "waiting_on_me": false, "summary": "", "updated_at": "", "events": 1,
      "sources": ["HEY"] }
  ],
  "opportunities": [
    { "id": "", "what": "", "deadline": "", "starts": "", "where": "", "link": "",
      "sender": "", "summary": "", "topics": [] }
  ],
  "jobs": [
    { "id": "", "sender": "", "subject": "", "summary": "", "received_at": "" }
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

## Money — <month>
- **Bills:** <merchant> <amount or "amount not shown"> due <date> (OVERDUE when it is)
### <CURRENCY>
in <income + refund> · out <paid + charged + due> — <n> subscriptions (last month: out <previous out>)
<repeat one block per currency, biggest `out` first; never merge currencies>

## Schedule
- <start> — <title> (<location>) · RSVP

## Code
- **<ref>** <title> — <state>: <where it stands>  (waiting on you first)

## Deadlines
- <deadline> — <what> (<where>)

## Radar
- **<Label>** — <headline>

## FYI (<n>)
- **<sender>** — <subject>: <why it matters>

_<n> noise skipped · <n> ephemeral · sources: <…> · <skipped notes>_
```

Omit any section with nothing in it. Keep each line to one sentence.

Write `digest.update.json`, call `commit_digest`, write `inbox-digest.md`, then
confirm in one line.
