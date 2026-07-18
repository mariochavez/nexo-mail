---
name: dashboard_designer
description: Produce the HTML dashboard for a triage run by RUNNING this skill's bundled render script over digest.json. The design is a fixed, versioned template ("Inbox Briefing" — a calm, modern, glanceable dashboard) rendered deterministically, so every run looks identical and is XSS-safe. Do not hand-write HTML.
---

# Dashboard Designer — "Inbox Briefing"

The dashboard's design and rendering are **bundled with this skill**, so every
run is byte-identical and safe:

- `assets/dashboard-template.html` — the fixed design: all CSS + a JS renderer
  that builds the page client-side from an embedded `digest.json` blob.
- `scripts/render_dashboard.rb` — injects the run's `digest.json` into the
  template's data blob, escaping the untrusted email text so it can't break out
  of the `<script>`. This is deterministic; it never depends on the model.

## What you do

The render script and template are **pulled from the configured paths**
(`[dashboard]` in config.toml — default: this skill's bundled `scripts/` and
`assets/`). The prompt hands you the exact command, which points at those paths;
run it **with the shell tool**, e.g.:

```sh
ruby "<configured render_dashboard.rb>" digest.json "<configured template.html>" dashboard.html
```

It reads `digest.json` from the workspace and writes `dashboard.html` there. Run
the command exactly as given, then confirm in one line. **Do not hand-write or
edit the HTML** — the template is the single source of truth for the design. If
the script prints an error (e.g. a malformed `digest.json`), report it plainly
and stop.

## The design the template produces (for maintainers)

You don't build this — but this is what `dashboard-template.html` renders, so a
maintainer editing the template keeps the intent:

- **Calm, modern, glanceable.** Light default + a real dark mode (system fonts,
  soft grey ground, white cards, gentle rounded corners, generous whitespace).
  One friendly blue accent; four soft category tints (blue = needs you, amber =
  money, green = schedule, purple = radar); semantic red/amber/green only for
  money & urgency, always paired with a label.
- **Top-down priority (inverted pyramid):** a top bar (wordmark, date, source
  chips) → a hero with a warm one-line headline and a **Needs-you to-do
  checklist** (check items off; the count ticks down) → **soft-tinted stat
  cards** (Need you / Money due / On the calendar / Radar) → prioritized sections:
  Money (due/charged/paid + a bar list + subscriptions), Schedule (agenda with
  RSVP/Set pills), Radar (topics as **2–3 tight bullets**, expandable), People
  (full notes), Threads (story arcs), Also worth knowing (FYI, collapsed).
- **Safe by construction:** every dynamic string reaches the DOM only via
  `textContent`; the data blob is escaped by the render script; links are
  `^https?://`-checked. Fully self-contained (no CDN/web fonts), opens from
  `file://`.
- **Calm interactions:** check off to-dos, stat cards jump to their section,
  live search, expand/collapse (View all / Read briefing / Show more).

To evolve the look, edit `assets/dashboard-template.html` (and the escaping in
`scripts/render_dashboard.rb` if you touch the data blob) — never by asking the
model to author HTML at run time.
