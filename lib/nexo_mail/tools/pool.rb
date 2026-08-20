# frozen_string_literal: true

require "async"
require "async/barrier"
require "async/semaphore"

module NexoMail
  module Tools
    # A bounded, order-preserving fan-out for the blocking I/O inside ONE tool call.
    #
    # The model can only issue tool calls sequentially unless tool concurrency is on
    # (see Config.tool_concurrency), so a batched read tool's own +execute+ is where
    # its I/O overlaps. That's what this is: give it the ids, get back the results in
    # the same order.
    #
    # Fibers, not threads. Measured on this machine (Ruby 4.0 / async 2.42): four
    # `sleep 0.4` subprocesses take 1.64s sequentially and 0.41s under Async — the
    # same as OS threads — because Async's scheduler hooks +process_wait+, +io_read+
    # and +io_wait+, so Open3 and Net::IMAP both yield instead of blocking. Four
    # IMAP connects to imap.gmail.com go 0.95s -> 0.17s the same way. Using fibers
    # keeps this composable with the reactor the workflow already runs its source
    # agents in (Nexo.concurrent), and spawns no OS threads.
    #
    # +Sync+ rather than +Async+ so this works either way: inside an existing reactor
    # it runs inline on it, and outside one it starts a reactor for the duration.
    module Pool
      MAX_IN_FLIGHT = 8

      module_function

      # Maps +items+ through the block with at most +size+ tasks in flight. Results
      # come back in INPUT order — callers zip them against the ids they passed.
      #
      # A raised exception is captured into that item's slot as { error: } and never
      # propagates: one dead thread id must not sink a batch of fifteen.
      def map(items, size: 4)
        items = Array(items)
        limit = size.to_i.clamp(1, MAX_IN_FLIGHT)
        return items.map { |item| guard { yield item } } if limit == 1 || items.size <= 1

        results = Array.new(items.size)
        Sync do
          semaphore = Async::Semaphore.new([limit, items.size].min)
          barrier = Async::Barrier.new(parent: semaphore)
          items.each_with_index { |item, i| barrier.async { results[i] = guard { yield item } } }
          barrier.wait
        ensure
          barrier&.stop
        end
        results
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
