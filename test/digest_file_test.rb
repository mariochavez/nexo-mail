# frozen_string_literal: true

require "test_helper"

# digest.json is read back by the model through ruby_llm's read_file, which cuts a
# line past 2,000 characters. So the file must stay plain JSON with short lines.
class DigestFileTest < NexoMailTest
  def layout(value) = NexoMail::DigestFile.send(:layout, value)

  def test_a_short_digest_is_one_line
    assert_equal '{"summary":"quiet day","items":[]}', layout({"summary" => "quiet day", "items" => []})
  end

  def test_a_long_section_is_one_entry_per_line_and_still_json
    digest = {
      "summary" => "busy",
      "items" => Array.new(40) { |i| {"id" => i, "subject" => "Message number #{i}", "note" => "x" * 60} },
      "money" => {"charges" => Array.new(30) { |i| {"vendor" => "Vendor #{i}", "amount" => i * 10.5} }}
    }

    text = layout(digest)

    assert_equal digest, JSON.parse(text)
    assert_operator text.lines.map(&:length).max, :<=, NexoMail::DigestFile.singleton_class::LINE + 200
    assert_operator text.lines.size, :>, 60
  end

  def test_one_huge_string_cannot_be_split_but_nothing_else_grows
    digest = {"note" => "y" * 5_000, "items" => Array.new(30) { |i| {"id" => i, "body" => "z" * 80} }}

    text = layout(digest)

    assert_equal digest, JSON.parse(text)
    long = text.lines.select { |line| line.length > 2_000 }
    assert_equal 1, long.size, "only the unsplittable string is long"
  end
end
