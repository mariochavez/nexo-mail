---
name: email_triage
description: Triage an email inbox — sort recent messages into Action / FYI / Noise and produce a short, prioritized markdown digest of what deserves attention. Read-only classification.
---

# Email Triage

Turn an inbox into a short, prioritized digest: read recent messages, sort each
into one bucket, and summarize the ones that matter.

## Buckets

Sort every message into exactly one bucket:

| Bucket | Meaning |
|---|---|
| **Action** | The reader must reply, decide, or do something. |
| **FYI** | Worth knowing; no response needed. |
| **Noise** | Newsletters, notifications, receipts — left out of the digest. |

Classify from the metadata you already have — sender, subject, and snippet. Open a
full message only to settle a genuinely ambiguous case.

## Always surface

Treat any message mentioning one of these as important — bucket it **Action** if it
asks for anything, otherwise **FYI**, and always include it in the digest:

- **FOTOSETIEMBRE**
- **500 Global** (also written **500 Startups** / **500.co**)

## Digest

Your deliverable is this markdown, most important first:

```markdown
# Inbox Digest — <date>

## Needs action (<n>)
- **<sender>** — <subject>: <the one thing that matters>

## FYI (<n>)
- **<sender>** — <subject>: <why it matters>

_<n> noise messages skipped._
```

Keep each line to one sentence and summarize in your own words, quoting at most a
short phrase.

## Saving

When the caller names a file to save to, write the digest there once with the write
tool, then reply with a one-line confirmation. Otherwise the digest itself is your
reply. Work with the reading tools you were given plus the write tool.

When a tool call fails, note the gap in the digest and carry on with what you read.
