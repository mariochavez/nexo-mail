---
name: email_triage
description: Triage the NEW mail in one email inbox and EXTRACT it into structured JSON — classify each message into Action / FYI / Noise, and pull the entities that matter (payments & charges, meetings, people, newsletter topics). Read-only. The deliverable is a JSON file, not prose.
---

# Email Triage → Structured Extraction

You read ONE inbox and turn the mail that is **new since the last run** into a
structured JSON array.
Downstream tooling (a financial roll-up, a schedule view, per-topic briefings,
a dashboard) is built entirely from the fields you emit — so extract carefully
and never invent values.

This is **read-only classification**. You never send, delete, or modify mail.

## First: find out what day it is, then set the window

**Call the `Today` tool before anything else.** You have no notion of the current
date and must never infer it from an email's contents. A run that did not know the
date published a schedule of appointments already two months past and reported 2023
receipts as current charges.

From what `Today` returns, work out the **run window**:

> **window_start = the 15th of `previous_month`.  window_end = `today`.**

So on 2026-08-19, with `previous_month: "2026-07"`, the window is
**2026-07-15 → 2026-08-19**: the whole current month, plus the tail of the previous
one so the 1st of a month is never a cliff.

Then **pass that window to the listing tools** — they do not know the date and will
not filter by it unless you tell them:

- HEY: `{"boxes": [...], "since": "<window_start>"}`
- Gmail: `{"since": "<window_start>"}`
- Apple Mail has no date filter on `get_emails`, so filter what it returns yourself
  against `date_received`, and use `search(..., after: "<window_start>")` when you
  need to reach further back.

**Never emit an item dated before `window_start`.** Comparing ISO dates is plain
string order — `"2026-06-18" < "2026-07-15"` — so once you know the window there is
nothing to guess.

## You only see new mail

Every message is triaged **once**. The listing tools keep a record of what earlier
runs were shown and leave it out: what comes back is only mail that arrived since,
plus any thread that has had new activity. Each listing reports how much it left
out as `already_triaged`.

What this changes for you:

- **Extract only what you are listed.** The items earlier runs extracted are
  already on record; `commit_extraction` merges yours into them. Do not try to
  reconstruct or re-read older mail to "complete" the picture.
- **The listing is the whole job.** Do not go looking in the workspace for earlier
  extraction files to compare against — there is nothing there you need, and every
  message you were listed is yours to classify.
- **An empty listing is a normal result.** It means nothing new arrived. Write
  `[]`, commit, and confirm — that is a complete, successful triage.
- **A thread that comes back has moved.** Emit it again with the SAME `id` and a
  `summary` of where the thread stands now; it replaces the earlier item.
- **Carry the `id` on every item** — the listing's own id for that message — so
  the record can tell a message it has from one it does not.

## Lanes: what kind of mail this is

Every item carries a `lane`. The bucket says whether the reader must act; the lane
says what KIND of mail it is, and each kind is kept and shown differently — a
newsletter issue is read once and gone in a month, a conversation matters for as
long as it is open, a verification code never mattered at all.

| `lane` | What goes in it | Emit |
|---|---|---|
| `conversation` | Mail from a person, or a thread the reader is part of: clients, collaborators, friends, family, an organisation writing to him specifically. | Full item. `people` when you know them. |
| `money` | Anything about money moving or owed: receipts, invoices, bills, statements, payouts, payment confirmations, renewals. | Full item with `payment` whenever a number is readable. |
| `dev` | Software work arriving as notifications: GitHub (PRs, issues, reviews, CI, Dependabot), RubyGems, error trackers, deploys, Slack digests. | Full item with `dev` (below). |
| `reading` | Newsletters and publications read for their content: Ruby and Rails news, tech news, photography and photobook publishers. | Item with `topics`. |
| `opportunity` | Something with a date to act by that is not a meeting: open calls, workshops, book launches, fairs, festivals, grant or submission deadlines, ticket sales. | Full item with `opportunity` (below). |
| `jobs` | Job boards and job alerts (RubyRoles, Rails Job Board, Calm Companies and the like). | One item per mailing, `summary` naming the two or three roles worth a look. |
| `ephemeral` | Mail whose value is gone once seen: verification codes, login alerts, delivery tracking, promotions and sales, "your export is ready". | Minimal item: `id`, `lane`, `bucket: "noise"`, `sender`, `sender_email`, `subject`, `received_at`, and an empty `summary`. Do not read its body. |

Rules:

- **One lane per item — the one it is most useful in.** A GitHub invoice is `money`,
  not `dev`. A newsletter announcing an open call with a deadline is `opportunity`.
  A person writing about an invoice is `conversation` (and still carries `payment`).
- **A listing row may arrive with a `lane` already on it.** That is where this
  sender's mail has gone before. Use it as the default and move on; depart from it
  only when this particular message is plainly something else.
- **The lane does not decide the bucket.** A `dev` item is `action` when a review is
  waiting on the reader; a `money` item is `action` when a bill is due.
- **Emit `ephemeral` items too** — minimally. They are counted, and they teach the
  record which senders are ephemeral.

### `dev`: one record per pull request or issue

Sixteen notifications about one pull request are one thing the reader needs to know:
where that PR stands. So every `dev` item names the thing it is about:

```json
"dev": { "ref": "owner/repo#123", "kind": "pr", "title": "Stop loading the world at boot",
         "state": "open", "waiting_on_me": true }
```

- `ref` — `owner/repo#number` for a PR or issue, exactly as GitHub writes it. For
  anything else, a short stable handle: `rubygems:nexo_ai`, `fragua:errors`,
  `slack:workspace`. The same thing must get the same `ref` every time.
- `kind` — `pr` | `issue` | `ci` | `release` | `error` | `security` | `chat` | `other`.
- `state` — `open` | `merged` | `closed` | `failing` | `passing` | `released`, when
  the message says so.
- `waiting_on_me` — `true` only when the reader's review, reply or fix is what it is
  waiting for (review requested, a question addressed to him, his PR failing CI).

Several notifications about the same `ref` in one listing: emit ONE item for it,
with the `id` of the newest and a `summary` of where it stands now.

### `opportunity`: what, and by when

```json
"opportunity": { "what": "HYDRA open call for photobook dummies", "deadline": "2026-12-15",
                 "starts": null, "where": "Mexico City", "link": "https://…" }
```

An invitation addressed to the reader for a set day and time (an opening, a talk, a
dinner, anything asking for an RSVP) is a `meeting`, not an `opportunity`: give it
`meeting` and the `conversation` lane so it lands in the schedule.

`deadline` is the last day to act; `starts` is when the event itself happens. Give
whichever the message states, as ISO dates; never guess one.

## Reading efficiently

Tool calls are sequential — every one is a full round trip — so the shape of your
reading matters as much as the extraction. Each listing already carries a
`snippet` of the message. **Classify from the snippet.** Most inboxes need no
body reads at all.

The pattern, per inbox:

1. **One listing call.** For HEY that is a single call for every box at once:
   `{"boxes": ["imbox", "feed", "papertrail", "setaside"]}`. Do not call it once
   per box.
2. **Classify everything you can from the listing.** Sender, subject, date and
   snippet settle the large majority of messages.
3. **If bodies are genuinely needed, collect ALL the ids first and make ONE
   batched read call.** Never one call per message. The read tools take a list:
   `{"uids": [40182, 40190, 40201]}` for Gmail, `{"thread_ids": [2103920594,
   2104108150]}` for HEY.
4. **Budget: at most two body-read calls per inbox.** If something is still
   unclear after that, classify it from what you have and move on — an item with
   an honest `summary` and no `payment` is worth more than another round trip.

Read a body only for a real reason: a receipt whose exact total the snippet cut
off, an invitation whose time you need, a genuinely ambiguous sender.

**Per-source notes**

- **HEY** — `thread_id` is NOT the same number as `id`. Read with `thread_id`;
  `id` is only for de-duplication. A posting with no `thread_id` (a bundled
  contact posting) has no readable body — classify it from the snippet alone.
- **Apple Mail** — the only source with no batched body read, and the one that
  runs away if you let it. A measured run made **48 mail calls** (27 × `search`,
  9 × `get_emails`, 8 × `get_email`, 4 × `list_mailboxes`) where six would have
  done, and took longer than the other two inboxes put together. So the budget
  here is hard, not a preference. Count as you go:
  - `list_accounts` / `list_mailboxes` — **do not call them.** Triage the inbox
    you were given. Discovering the mailbox layout tells you nothing about
    today's mail.
  - `get_emails` — **once.** That is your listing.
  - `search` — **at most twice**, always with `after:` set to the window start.
    It returns a `content_snippet` for many messages in one call, which is the
    only reason to prefer it over `get_email`. A third search means you are
    exploring, not reading.
  - `get_email` — **at most twice.** One message per call, so it is the last
    resort, not the habit.

  Six mail calls is a complete Apple Mail triage. If something is still unclear
  after that, classify it from what you have and move on: past this point the run
  is only getting slower, and an item with an honest `summary` and no `payment`
  is worth more than another round trip.

## The deliverable: a JSON array, then a commit

Two steps, in this order:

1. **Write** a single JSON array to the `*.new.json` file the caller names, with
   the write tool. No markdown, no prose in the file — just the array. One object
   per NEW message — several notifications about one `dev` thing collapse into
   one, and `ephemeral` mail gets its minimal item; `[]` if nothing new arrived.
2. **Call `commit_extraction`** once, with `file` set to that same file,
   `keep_since` set to your `window_start`, and `keep_by_lane` taken straight from
   `Today`'s `days_ago` — never subtract days yourself:

   ```json
   { "conversation": "<days_ago 90>", "money": "<days_ago 90>", "opportunity": "<days_ago 90>",
     "dev": "<days_ago 30>", "reading": "<days_ago 30>",
     "jobs": "<days_ago 14>", "ephemeral": "<days_ago 7>" }
   ```

   It merges your items with what earlier
   runs kept, writes the inbox's full extraction file, and records the mail you
   were listed as triaged. **Skip this and the run counts as failed** — the same
   mail is simply offered again next time.

Then reply with a one-line confirmation.

```json
[
  {
    "id": "40182",
    "lane": "money",
    "bucket": "action",
    "category": "payment",
    "sender": "Netflix",
    "sender_email": "info@netflix.com",
    "subject": "Your receipt for July",
    "summary": "Monthly subscription charged to your card ending 4242.",
    "received_at": "2026-07-15",
    "importance": 60,
    "payment": {
      "merchant": "Netflix",
      "amount": 15.99,
      "currency": "USD",
      "direction": "charged",
      "kind": "subscription",
      "due_date": null
    }
  }
]
```

### Fields

Required on every item:

| Field | Values / shape |
|---|---|
| `id` | the message's id exactly as the listing gave it — HEY posting `id`, Gmail `uid`, Apple Mail `id`. Not the `thread_id`. Never invent one. |
| `lane` | `conversation` \| `money` \| `dev` \| `reading` \| `opportunity` \| `jobs` \| `ephemeral` — see [Lanes](#lanes-what-kind-of-mail-this-is). |
| `bucket` | `"action"` \| `"fyi"` \| `"noise"` — Action = reader must reply/decide/do; FYI = worth knowing, no response; Noise = newsletters/notifications/receipts (still emit if it carries a payment, meeting, or topic worth a picture). |
| `category` | one of: `payment`, `meeting`, `personal`, `work`, `newsletter`, `notification`, `travel`, `security`, `other`. |
| `sender` | display name (fall back to the address). |
| `sender_email` | the address, or `null` if unknown. |
| `subject` | the subject line, verbatim. |
| `summary` | ONE sentence, in your own words, quoting at most a short phrase. The single thing that matters. |
| `received_at` | ISO date or datetime from the message metadata; `null` if unavailable. Never guess a date. |

Optional — include ONLY when the message genuinely carries it:

- `importance`: integer 0–100 (your judgement of how much this matters to the reader).
- `thread_id`: the provider's thread/conversation id, if the tools expose it.
- `payment`: see [financial_summary](../financial_summary/SKILL.md). Attach to any
  receipt, invoice, charge, bill, refund, or payment-due message. Never fabricate
  an amount — omit `payment` if you can't read a real number.
- `meeting`: `{ "title", "start", "end", "location", "link", "rsvp" }` — for
  calendar invites, scheduling requests, or messages proposing a specific time.
  `start`/`end` are ISO datetimes; `rsvp` is `true` when a response is expected.
- `people`: array of person names the reader personally knows who are central to
  the message (for `personal` items especially). Omit for machine senders.
- `dev`: required on every `dev`-lane item — see above.
- `opportunity`: required on every `opportunity`-lane item — see above.
- `topics`: array of short topic tags for `newsletter` items — see
  [interest_radar](../interest_radar/SKILL.md). E.g. `["ruby", "rails"]`,
  `["photography"]`.

## Buckets, briefly

| Bucket | Meaning |
|---|---|
| **action** | Reply, decide, pay, RSVP, or do something. |
| **fyi** | Worth knowing; no response needed. |
| **noise** | Newsletters, notifications, receipts. |

A newsletter is usually `noise` by bucket but still emit it when it has
`topics` (so the topic radar can build a picture) or a `payment`. A receipt is
`noise` by bucket but emit it with a `payment` so the money picture is complete.

## Always surface

Treat any message mentioning one of these as important — set `bucket` to
`action` if it asks for anything, otherwise `fyi`, and always emit it:

- **FOTOSETIEMBRE**
- **500 Global** (also written **500 Startups** / **500.co**)

## Rules

- Extract, don't summarize into prose. The file is data.
- Never invent amounts, dates, times, or names. Omit the optional field instead.
- One object per message, with its `lane`. Deduplicate obvious repeats of the same
  thread, and collapse notifications about the same `dev` `ref`.
- If a tool call fails, extract what you can from what you read and carry on;
  the array you write is still valid JSON.
- Write the array exactly once, call `commit_extraction` exactly once, then
  confirm in one line.
