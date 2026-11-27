# frozen_string_literal: true

module NexoMail
  module Tools
    # Applies the digest builder's update file to `digest.json`.
    #
    # The builder decides what the digest says; this does the part that must not be
    # approximate — replace exactly the top-level keys it wrote and leave every other
    # section byte-for-byte as it was — so taking in three new messages does not mean
    # re-emitting thirty kilobytes of unchanged JSON. It is also the ONLY thing that
    # marks items as digested: a builder that never calls it leaves them waiting for
    # the next run.
    class CommitDigest < RubyLLM::Tool
      description <<~DESC.strip
        Save the digest. Call it after writing `#{DigestFile::UPDATE}`.

        That file is a JSON object of TOP-LEVEL digest keys. Each key in it replaces
        that key in `#{DigestFile::FILE}` whole; every key you leave out is kept exactly as
        it is. On a full build it must hold the entire digest.

        To change single entries of a list without re-writing the list, add an
        `#{DigestFile::EDIT}` key instead of the list itself:
        `{"#{DigestFile::EDIT}": {"action": {"put": [<entry>, …], "drop": ["<id>", …]}}}`.
        A put entry replaces the one with the same identity, or is added first.
        Lists and their identity field: #{DigestFile::EDITABLE.map { |list, field| "#{list} by `#{field}`" }.join(", ")}.

        Returns the keys replaced, the lists edited, and `lists` — how long each list
        is as saved, beside the `counts` you stated. If they disagree, write a new
        `#{DigestFile::UPDATE}` holding only the corrected `counts` and call again.
      DESC

      def execute
        file = DigestFile.update_path
        return JSON.generate(error: "#{DigestFile::UPDATE} does not exist — write the keys that changed to it first") unless File.exist?(file)

        done = DigestFile.commit(JSON.parse(File.read(file, encoding: "UTF-8")))
        # Gone once applied, so a correction is a fresh write, not a read-then-write.
        FileUtils.rm_f(file)
        JSON.generate(done.merge(written: DigestFile::FILE))
      rescue JSON::ParserError => e
        JSON.generate(error: "#{DigestFile::UPDATE} is not valid JSON (#{e.message[0, 120]}) — rewrite it and call again")
      rescue => e
        JSON.generate(error: e.message)
      end
    end
  end
end
