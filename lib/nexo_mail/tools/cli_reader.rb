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
      module_function

      def json(*argv, timeout: Config.cli_timeout)
        out, err, status = Nexo::Sandboxes::Subprocess.capture(ENV.to_h, *argv, timeout: timeout)
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
