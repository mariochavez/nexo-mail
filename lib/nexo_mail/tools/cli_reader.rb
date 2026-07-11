# frozen_string_literal: true

module NexoMail
  module Tools
    # Runs a read-only CLI as an ARGV ARRAY via Open3 (never a shell string), so
    # nothing the model supplies is interpreted as shell syntax — no injection
    # surface. Returns parsed JSON on success, { raw: } when output isn't JSON, or
    # { error: } on a non-zero exit / missing binary (recoverable for the model).
    module CliReader
      module_function

      def json(*argv)
        out, err, status = Open3.capture3(*argv)
        unless status.success?
          return {error: "#{argv.first} exited #{status.exitstatus}: #{err.strip[0, 300]}"}
        end

        begin
          JSON.parse(out)
        rescue JSON::ParserError
          {raw: out.strip[0, 4000]}
        end
      rescue Errno::ENOENT
        {error: "`#{argv.first}` not found on PATH — is it installed and authenticated?"}
      end
    end
  end
end
