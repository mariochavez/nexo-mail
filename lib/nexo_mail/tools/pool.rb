# frozen_string_literal: true

module NexoMail
  module Tools
    # A bounded, order-preserving fan-out for the blocking I/O inside ONE tool call.
    #
    # The model issues one batched call — 15 thread ids, 4 boxes — and the overlap
    # has to happen inside that tool's own +execute+. That's what this is: give it
    # the items, get back the results in the same order.
    #
    # +Config.tool_concurrency+ picks how: fibers by default (through
    # +Nexo.concurrent+, a bounded Async fan-out — Async's scheduler hooks
    # +process_wait+/+io_read+/+io_wait+, so +Open3+ and +Net::IMAP+ yield instead of
    # blocking, and it composes with the reactor the workflow already runs its source
    # agents in); +threads+ works too, and +Tools::Hey::LOCK+ is a Mutex, which is
    # safe under either. Nothing here reaches into ruby_llm internals.
    module Pool
      MAX_IN_FLIGHT = 8

      module_function

      # Maps +items+ through the block with at most +size+ of them in flight.
      # Results come back in INPUT order — callers zip them against the ids they
      # passed.
      #
      # A raised exception is captured into that item's slot as { error: } and never
      # propagates: one dead thread id must not sink a batch of fifteen. That
      # +guard+ is also what keeps Nexo.concurrent's fail-fast (it re-raises the
      # first error and stops the rest) from ever triggering.
      def map(items, size: 4)
        items = Array(items)
        limit = size.to_i.clamp(1, MAX_IN_FLIGHT)
        mode = Config.tool_concurrency
        return items.map { |item| guard { yield item } } unless overlap?(mode, limit, items)

        if mode.to_sym == :fibers
          Nexo.concurrent(max_in_flight: limit) { |c| items.each { |item| c.add { guard { yield item } } } }
        else
          # Threads: the bound is a slice. Gmail caps simultaneous IMAP connections
          # per account and `hey` serializes on the keyring; neither wants 15 at once.
          items.each_slice(limit).flat_map do |slice|
            slice.map { |item| Thread.new { guard { yield item } } }.map(&:value)
          end
        end
      end

      # Whether to fan out at all. One item, a limit of one, or concurrency switched
      # off all mean "just run them here".
      def overlap?(mode, limit, items)
        limit > 1 && items.size > 1 && %i[fibers threads].include?(mode.to_s.to_sym)
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
