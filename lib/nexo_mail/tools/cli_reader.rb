# frozen_string_literal: true

module NexoMail
  module Tools
    # Runs a read-only CLI as an ARGV ARRAY (never a shell string), so nothing the
    # model supplies is interpreted as shell syntax — no injection surface. Returns
    # parsed JSON on success, { raw: } when output isn't JSON, or { error: } on a
    # non-zero exit, a missing binary or a timeout (recoverable for the model).
    #
    # Through Nexo's Subprocess rather than Open3, for the timeout: it runs the
    # command in its own process group and kills the group when the time is up. A
    # hung `hey` used to hold Tools::Hey::LOCK for good.
    module CliReader
      # What a CLI is started with. Not the whole environment: an API key in this
      # process is none of `hey`'s business. `hey` signs in through the macOS
      # keyring, which needs only the user's identity and home (checked: `hey auth
      # status` and a box read both work with exactly these).
      ENVIRONMENT = %w[HOME PATH USER LOGNAME LANG LC_ALL TMPDIR XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME].freeze

      module_function

      def json(*argv, timeout: Config.cli_timeout)
        out, err, status = Nexo::Sandboxes::Subprocess.capture(ENV.to_h.slice(*ENVIRONMENT), *argv, timeout: timeout)
        return {error: "#{argv.first} exited #{status.inspect}: #{err.strip[0, 300]}"} unless status == 0

        begin
          JSON.parse(out)
        rescue JSON::ParserError
          {raw: out.strip[0, 4000]}
        end
      rescue Timeout::Error
        {error: "`#{argv.first}` did not answer in #{timeout}s and was stopped"}
      rescue Errno::ENOENT
        {error: "`#{argv.first}` not found on PATH — is it installed and authenticated?"}
      end
    end
  end
end
