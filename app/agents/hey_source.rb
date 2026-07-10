# frozen_string_literal: true

# HEY — reached through the `hey` CLI via read-only tool wrappers.
class HeySource < SourceAgent
  def self.source_tools = [HeyImbox, HeyThread]

  def self.availability
    return "hey not found on PATH" unless command?("hey")

    data = CliReader.json("hey", "auth", "status", "--json")
    data = data.is_a?(Hash) ? (data["data"] || {}) : {}
    return "hey not authenticated (run `hey auth login`)" unless data["authenticated"]
    return "hey session expired (run `hey auth login`)" if data["expired"]

    nil
  rescue
    nil # if the check itself errors, let the run attempt and fail gracefully
  end
end
