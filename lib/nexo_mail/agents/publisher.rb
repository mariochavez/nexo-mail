# frozen_string_literal: true

module NexoMail
  module Agents
    # Publishes the dashboard. The design and the render live in the
    # dashboard_designer SKILL (a fixed template + a render script). The workflow
    # STAGES both into the workspace before this agent runs — so they are reachable
    # through its permission-gated read/glob tools, which skill files outside the
    # sandbox are not — and this agent RUNS the script with the Shell tool. Every
    # path in the command is workspace-relative.
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
      # tool (every sandbox tier below supports it). Mode stays :read_only.
      permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write shell])

      # WHERE the one shell in this app runs. It reaches no mail and needs no
      # network, so it is the single stage that can be moved off the host entirely:
      # `[dashboard] sandbox = "docker"` puts it in a throwaway container with no
      # network, dropped capabilities and a read-only rootfs over an ephemeral
      # scratch. "local" (the default) keeps it in the shared workspace.
      #
      # A lazy READER override, like .requires above: Config is not loaded until
      # CLI.run, and Nexo resolves the sandbox on first touch. Because the agent
      # resolves this itself rather than being handed one, Nexo also OWNS it and
      # closes it in #close — no teardown code here, and no leaked container.
      def self.sandbox
        return :local unless Config.dashboard_containerized?

        {type: Config.dashboard_sandbox.to_sym, image: Config.dashboard_image,
         network: :none, readonly_rootfs: Config.dashboard_sandbox != "apple"}
      end

      def self.prompt_key = "publisher"

      # The one artifact this agent exists to produce. The workflow collects every
      # declared name onto the run record after the agent finishes, so the
      # deliverable outlives the workspace it was written into (nexo_ai >= 0.9).
      produces "dashboard.html"

      # Fail fast when the sandbox has no usable Ruby at all, instead of letting the
      # model burn a turn on a shell command that dies with "ruby: command not
      # found". Checked once, before the first turn, against the agent's OWN sandbox
      # — so what gets verified is the environment the render command will actually
      # run in, not the one your terminal has.
      #
      # Providing the interpreter is the operator's job, not this app's: the sandbox
      # shell runs with a narrowed PATH (PATH/HOME/LANG only), so make sure a Ruby is
      # reachable there — and pin `[dashboard] ruby` to an absolute path when yours is
      # version-managed (mise/asdf/rbenv). This declaration only says out loud what
      # the Publisher cannot work without.
      requires commands: {"ruby" => ">= 3.0"}

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
