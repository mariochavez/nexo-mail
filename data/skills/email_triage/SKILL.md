---
name: email_triage
description: Triage one email inbox and EXTRACT it into structured JSON — classify each recent message into Action / FYI / Noise, and pull the entities that matter (payments & charges, meetings, people, newsletter topics). Read-only. The deliverable is a JSON file, not prose.
---

# Email Triage → Structured Extraction

You read ONE inbox and turn its recent messages into a structured JSON array.
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

## The deliverable: a JSON array

When the caller names a file, write a single JSON array to it with the write
tool, then reply with a one-line confirmation. No markdown, no prose in the
file — just the array. One object per message you keep (skip pure Noise unless
an "always surface" rule applies).

```json
[
  {
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
- One object per kept message. Deduplicate obvious repeats of the same thread.
- If a tool call fails, extract what you can from what you read and carry on;
  the array you write is still valid JSON.
- Write the array exactly once, then confirm in one line.
