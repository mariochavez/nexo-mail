# frozen_string_literal: true

module NexoMail
  module Agents
    # Publishes the dashboard. The design and the render live in the
    # dashboard_designer SKILL (a fixed template + a render script); the workflow
    # stages both into the workspace, and this agent RUNS the script with the Shell
    # tool to produce a byte-identical `dashboard.html` from `digest.json`.
    #
    # SECURITY — deliberate, scoped exception to the app's read-only-by-construction
    # guarantee: the Publisher is the ONLY agent granted `:shell`. It reaches no mail
    # (attaches no mail tools), only reads the already-produced `digest.json`, and
    # runs the developer-authored, bundled render script inside its sandbox. Every
    # mail-reading agent stays strictly read-only (no shell).
    class Publisher < SourceAgent
      # Reset inherited extraction skills — the publisher only renders the dashboard.
      @skills = %i[dashboard_designer]

      # Add :shell on top of the sandbox read/glob/write, so Nexo attaches the Shell
      # tool (the Local sandbox supports it). Mode stays :read_only.
      permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write shell])

      def self.prompt_key = "publisher"

      instructions <<~TXT
        You render the dashboard by running the render command the prompt gives you
        with the shell tool — you do NOT hand-write HTML. The command runs the
        dashboard_designer skill's render script over the configured template and the
        workspace `digest.json`, producing `dashboard.html`. Run it exactly as given,
        then confirm in one line. If the script prints an error, report it plainly and
        stop — do not try to author the HTML yourself.
      TXT
    end
  end
end
