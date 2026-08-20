# frozen_string_literal: true

module NexoMail
  module Tools
    # A bounded, order-preserving fan-out for the blocking I/O inside ONE tool call.
    #
    # The model issues one batched call — 15 thread ids, 4 boxes — and the overlap
    # has to happen inside that tool's own +execute+. That's what this is: give it
    # the items, get back the results in the same order.
    #
    # The concurrency itself is ruby_llm's. +RubyLLM::ToolConcurrency+ is the same
    # machinery that overlaps several tool calls from a single assistant turn, so
    # using it here means ONE setting — +Config.tool_concurrency+ — governs both
    # axes, and this file carries no reactor plumbing of its own. Fibers by default
    # (Async's scheduler hooks +process_wait+/+io_read+/+io_wait+, so +Open3+ and
    # +Net::IMAP+ yield instead of blocking, and it composes with the reactor the
    # workflow already runs its source agents in); +threads+ works too, and
    # +Tools::Hey::LOCK+ is a Mutex, which is safe under either.
    module Pool
      MAX_IN_FLIGHT = 8

      module_function

      # Maps +items+ through the block with at most +size+ of them in flight.
      # Results come back in INPUT order — callers zip them against the ids they
      # passed.
      #
      # A raised exception is captured into that item's slot as { error: } and never
      # propagates: one dead thread id must not sink a batch of fifteen. That
      # +guard+ is also what keeps ToolConcurrency's own fail-fast (it re-raises the
      # first error and abandons the rest) from ever triggering.
      def map(items, size: 4)
        items = Array(items)
        limit = size.to_i.clamp(1, MAX_IN_FLIGHT)
        mode = Config.tool_concurrency
        return items.map { |item| guard { yield item } } unless overlap?(mode, limit, items)

        # ToolConcurrency has no in-flight bound of its own — it starts one task per
        # entry — so the bound is a slice. Gmail caps simultaneous IMAP connections
        # per account and `hey` serializes on the keyring; neither wants 15 at once.
        items.each_slice(limit).flat_map do |slice|
          calls = slice.each_with_index.to_h { |item, i| [i, item] }
          RubyLLM::ToolConcurrency.run(mode, calls) { |item| guard { yield item } }.map(&:last)
        end
      end

      # Whether to fan out at all. One item, a limit of one, or a concurrency setting
      # ruby_llm doesn't support all mean "just run them here".
      def overlap?(mode, limit, items)
        limit > 1 && items.size > 1 && RubyLLM::ToolConcurrency.supported?(mode)
      end

      # Runs the block, turning any exception into a recoverable { error: } value so
      # the caller can report it per-item instead of losing the whole batch.
      def guard
        yield
      rescue => e
        {error: "#{e.class}: #{e.message}"}
      end
    end
  end
end
