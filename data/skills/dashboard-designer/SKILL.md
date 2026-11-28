---
name: dashboard-designer
description: Produce the HTML dashboard for a triage run by RUNNING this skill's bundled render script over digest.json. The design is a fixed, versioned template ("Inbox Briefing" — a reading column with a glanceable side rail) rendered deterministically, so every run looks identical and is XSS-safe. Do not hand-write HTML.
compatibility: Needs a Ruby 3.0+ interpreter reachable from the sandbox shell, and the shell tool to run it. Without those, say so and stop — there is no fallback and hand-authored HTML is not one.
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

- **Built for reading, not for filling a grid.** Light default + a real dark mode
  (system fonts, soft grey ground, white cards). One blue accent; category tints
  (blue = needs you, amber = money, green = schedule, purple = radar); red/amber/green
  only for urgency and money, always paired with a label.
- **No box may leave a hole.** The earlier design paired cards in a two-column grid,
  so a short card beside a tall one left a large blank area. The layout is now:
  - a **masthead**: the headline as one readable paragraph (not a giant heading),
    with the date and sources;
  - a **sticky bar**: section links that carry the counts (18 need you · $ due ·
    1 event · …) and the search field (`/` focuses it);
  - a **reading column** — Needs you (a checklist, six shown, the rest behind
    "Show more"), Radar and Threads (short cards in CSS *columns*, a masonry, so
    uneven heights pack instead of leaving gaps), Also worth knowing (a dense
    sender / subject / age list);
  - a **side rail** that stays in view — Schedule, Money, People — for the things
    you glance at rather than read. Below 920px it becomes one column.
- **Short by default, complete on demand.** A radar topic shows three bullets, a
  thread four lines, a person three; each expands in place. Searching reveals
  everything that matches, including collapsed content.
- **Checked items stay checked.** To-dos are remembered per briefing in
  `localStorage`, keyed by the run's timestamp.
- **Dates are calendar days.** A date-only value (`2026-12-14`) is parsed as a local
  day; parsed as UTC it rendered as the day before.
- **Safe by construction:** every dynamic string reaches the DOM only via
  `textContent`; the data blob is escaped by the render script; links are
  `^https?://`-checked. Fully self-contained (no CDN/web fonts), opens from
  `file://`.
- **Calm interactions:** check off to-dos, jump from the sticky bar, live search,
  expand and collapse in place. It prints with everything expanded.

To evolve the look, edit `assets/dashboard-template.html` (and the escaping in
`scripts/render_dashboard.rb` if you touch the data blob) — never by asking the
model to author HTML at run time.
