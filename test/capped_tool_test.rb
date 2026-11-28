# frozen_string_literal: true

require "test_helper"

# The body cap on Apple Mail's MCP replies. It once measured the reply's object
# address instead of its text, so it never cut anything; these pin the real thing.
class CappedToolTest < NexoMailTest
  Fake = Struct.new(:reply) do
    def call(**) = reply

    def name = "get_email"

    def description = "Reads one message"
  end

  def result(text) = RubyLLM::MCP::Result.new({"content" => [{"type" => "text", "text" => text}]})

  def capped(reply, max: 100) = NexoMail::Tools::CappedTool.new(tool: Fake.new(reply), max_chars: max)

  def test_a_long_mcp_reply_is_cut_and_says_so
    out = capped(result("a" * 5_000)).call(id: 1)

    assert_kind_of String, out
    assert out.start_with?("a" * 100)
    assert_includes out, "truncated"
    assert_operator out.length, :<, 400
  end

  def test_a_short_reply_passes_through_untouched
    reply = result("short")

    assert_same reply, capped(reply).call(id: 1)
  end

  def test_a_plain_string_reply_is_capped_too
    assert_includes capped("b" * 500).call, "truncated"
  end

  def test_execute_goes_through_the_cap_and_other_methods_through_to_the_tool
    tool = capped(result("c" * 500))

    assert_includes tool.execute(id: 1), "truncated"
    assert_equal "Reads one message", tool.description
    assert_equal "get_email", tool.name
  end
end
