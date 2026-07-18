---
name: interest_radar
description: Turn newsletters and topic mail into a "what's going on" briefing per interest (Ruby, Rails, photography, and any recurring theme in the inbox). Tag items with topics during extraction; synthesize a short per-topic picture during merge.
---

# Interest Radar

Newsletters and community mail are Noise to the action list but valuable as a
_picture_: what's happening in the reader's worlds — **Ruby**, **Ruby on
Rails**, **photography**, and any other theme that recurs in this inbox. This
skill has two jobs depending on which stage you're in.

## During extraction (per source)

For any `newsletter` (and topical `work`/`other`) item, add a `topics` array of
short, lower-case tags. Prefer these canonical tags when they fit, and add your
own for anything else that recurs:

- `ruby` — the Ruby language, gems, RubyGems, releases, RubyKaigi/conf talks.
  Senders like Ruby Weekly, The Ruby Dispatch, RubyFlow, Short Ruby Newsletter.
- `rails` — Ruby on Rails, Hotwire/Turbo/Stimulus, Active*, Rails releases.
  Senders like This Week in Rails, Rails Weekly, GoRails, Hotwire Weekly.
- `tech` — everything else technical: programming languages, web dev, AI/ML,
  developer tools, infrastructure/cloud, security, startups/industry. Senders
  like Hacker Newsletter, TLDR, Pragmatic Engineer, Bytes, Console, changelog,
  GitHub/PyPI/npm digests, conference CFPs.
- `photography` — cameras, lenses, technique, gear, shows, contests, photo
  communities. Senders/sources like PetaPixel, DPReview / Digital Photography
  Review, Fstoppers, PhotoShelter, 500px, Shotkit, B&H/Adorama photo mailers,
  and anything mentioning **FOTOSETIEMBRE**. If a message is clearly about
  making or viewing photographs, tag `photography` even if the sender is unknown.

Ruby and Rails are the reader's core interests — tag them precisely and never let
a Ruby/Rails issue get swallowed under the broad `tech` tag (it can carry both,
but `ruby`/`rails` must be present when it applies). Tag by what the issue is
_about_, not just the sender: a "Ruby Weekly" issue that's mostly Rails gets
`["ruby", "rails"]`; a general dev newsletter that leads with a Rails release
gets `["tech", "rails"]`. Keep tags to 1–3 per item. Put one crisp fact in the
item's `summary` — the specific thing this issue leads with, not "this week's
roundup."

## During synthesis (across all sources)

Group the tagged items by topic and write a short **briefing** per topic. For the
reader's tracked interests — **`ruby`, `rails`, `photography`** — surface the
topic even from a **single** item; don't require a second one. For the broad
`tech` topic, surface it when there's a reasonable picture (roughly 2+ items).
Lead the radar with **Ruby** then **Rails** (the strongest interests), then the
rest. Condense each topic into **2–3 tight bullets** — the reader skims bullets
far faster than a paragraph, and the dashboard renders them as a list:

- Each bullet is ONE concrete development — a release, a shift, a notable piece —
  named with specifics (versions, tools, names) over vibes. ≤ ~15 words.
- Order bullets most-important first. 2 is fine; never more than 3.
- Also give a one-line `headline` (the single biggest thing) and keep a short
  `briefing` paragraph as a fallback for renderers that don't show bullets.
- Cite the items feeding the topic by subject so the dashboard can link back.

Emit briefings in the synthesis JSON as:

```json
{
  "topics": [
    {
      "topic": "ruby",
      "label": "Ruby",
      "headline": "Ruby 3.5 preview lands; Prism is now the default parser",
      "bullets": [
        "Ruby 3.5 preview ships with Prism as the default parser",
        "Experimental namespaced constants land for testing",
        "Several gems already publishing 3.5-compatible releases"
      ],
      "briefing": "Two newsletters led with the Ruby 3.5 preview…",
      "item_subjects": ["Ruby Weekly #672", "The Ruby Dispatch"],
      "count": 3
    }
  ]
}
```

Use a human `label` (`"Ruby"`, `"Ruby on Rails"`, `"Photography"`, `"Tech"`) and
keep the lower-case `topic` as the machine key. Order them Ruby → Rails →
Photography → Tech → anything else. Only surface topics that actually have signal
this run — never pad the radar with empty themes. But do NOT drop `ruby`,
`rails`, or `photography` just because there's a single item; a lone Ruby release
or one photography issue is still a briefing worth showing.
