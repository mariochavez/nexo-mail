---
name: email_triage
description: Triage one email inbox and EXTRACT it into structured JSON — classify each recent message into Action / FYI / Noise, and pull the entities that matter (payments & charges, meetings, people, newsletter topics). Read-only. The deliverable is a JSON file, not prose.
---

# Email Triage → Structured Extraction

You read ONE inbox and turn its recent messages into a structured JSON array.
Downstream tooling (a financial roll-up, a schedule view, per-topic briefings,
a dashboard) is built entirely from the fields you emit — so extract carefully
and never invent values. Classify from the metadata you already have (sender,
subject, snippet); open a full message only to settle a genuinely ambiguous
case or to read a receipt/invitation you must extract numbers or times from.

This is **read-only classification**. You never send, delete, or modify mail.

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
