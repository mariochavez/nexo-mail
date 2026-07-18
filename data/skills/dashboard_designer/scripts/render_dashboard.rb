#!/usr/bin/env ruby
# frozen_string_literal: true

# render_dashboard.rb — the deterministic dashboard renderer, bundled WITH the
# dashboard_designer skill (not with the app). The Publisher agent copies this
# script + the template into its workspace and runs:
#
#   ruby render_dashboard.rb digest.json dashboard-template.html dashboard.html
#
# It injects the run's digest data into the fixed template's JSON blob so the
# design is byte-identical every run, and it does the ONE security-critical step
# — escaping the untrusted email text so it can't break out of the <script> — in
# code, never trusting the model to get it right. The template renders entirely
# client-side from that blob (data only ever reaches the DOM via textContent).
require "json"

digest_path   = ARGV[0] || "digest.json"
template_path = ARGV[1] || "dashboard-template.html"
out_path      = ARGV[2] || "dashboard.html"

abort "render_dashboard: #{digest_path} not found" unless File.exist?(digest_path)
abort "render_dashboard: #{template_path} not found" unless File.exist?(template_path)

# Parse to validate, then re-serialize compactly (so a pretty-printed digest.json
# still embeds cleanly). A malformed digest is fatal here — better to fail loudly
# than to ship a broken dashboard.
data = JSON.parse(File.read(digest_path))

# `ascii_only: true` escapes every non-ASCII char (accents, arrows, emoji) to \uXXXX,
# so the blob is pure ASCII and renders correctly no matter how the browser guesses
# the file's charset — no more "México" → "MÃ©xico" mojibake. Then escape `<>&` +
# the JS line separators so the untrusted email text can't break out of the
# <script type="application/json"> (neutralizing `<` defeats a `</script>` breakout).
safe = JSON.generate(data, ascii_only: true).gsub(/[<>&  ]/) { |c| format("\\u%04x", c.ord) }

template = File.read(template_path)
unless template.include?("__DIGEST_JSON__")
  abort "render_dashboard: template is missing the __DIGEST_JSON__ placeholder"
end

File.write(out_path, template.sub("__DIGEST_JSON__", safe))
puts "render_dashboard: wrote #{out_path} (#{File.size(out_path)} bytes)"
