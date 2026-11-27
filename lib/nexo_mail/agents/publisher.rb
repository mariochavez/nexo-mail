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
    class Publisher < Base
      skills :dashboard_designer

      # Add :shell on top of the sandbox read/glob/write, so Nexo attaches the Shell
      # tool. Mode stays :read_only.
      permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write shell])

      # WHERE the one shell in this app runs — `[dashboard] sandbox`. The FILES are
      # always the shared workspace; what changes is what a shell command can reach:
      #
      #   "confined"  an OS sandbox (Seatbelt / Bubblewrap): writes only inside the
      #               workspace, no home directory, no network. The default wherever
      #               it can run.
      #   "docker" /  a throwaway container per command, no network, capabilities
      #   "apple"     dropped, read-only root, with only the workspace bound in.
      #   "local"     an ordinary host process. Unfenced; `--check` says so.
      #
      # All three fences are the same Nexo seam: a :local sandbox whose shell runs
      # through an `isolation:`. So no stage ever has a workspace of its own, and
      # nothing has to be copied in or out of one.
      #
      # A lazy READER override: Config is not loaded until CLI.run, and Nexo resolves
      # the sandbox on first touch.
      def self.sandbox
        case Config.dashboard_sandbox
        when "local" then :local
        when "confined" then {type: :local, isolation: :confined, readable: Config.dashboard_readable}
        else {type: :local, isolation: container_runner, readable: Config.dashboard_readable(ruby: false)}
        end
      end

      # One hardened, network-less container per render command.
      def self.container_runner
        Nexo::Sandboxes::ContainerRunner.new(image: Config.dashboard_image, runtime: Config.dashboard_sandbox.to_sym)
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
