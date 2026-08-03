# frozen_string_literal: true

module Smith
  # Ambient execution attribution: an immutable, thread-local description of
  # where execution currently is (run identity, transition, fan-out branch,
  # optimizer round). Workflow execution scopes install it; observability
  # consumers (traces, events, usage recording) read it, so emitted facts
  # carry correlation without any consumer knowing about the workflow.
  #
  # Attribution values are opaque identifiers, never content: the trace
  # content policy does not treat them as payload. `execution_key` defaults
  # to the workflow's persistence key during persisted runs; hosts running
  # non-persisted workflows can seed an outer scope explicitly:
  #
  #   Smith::Attribution.with(execution_key: "host-run-42") { workflow.run! }
  #
  # Installation inside workflow internals is a plain assignment
  # (Attribution.install) because restoration there is owned by the
  # surrounding ThreadContextSnapshot, which tracks the attribution thread
  # key alongside the other per-step thread state.
  module Attribution
    THREAD_KEY = :smith_attribution

    Context = Data.define(:execution_key, :transition, :from, :to, :branch_key, :round, :workflow) do
      # Overlay semantics: nil overrides are ignored so an inner scope can
      # only add or replace attribution, never blank an outer value.
      def merge(**overrides)
        filtered = overrides.compact
        return self if filtered.empty?

        override(**filtered)
      end

      # Replacement semantics: sets the given fields verbatim, nil included,
      # so a scope that owns a field can reset it (a step whose transition
      # declares no `from` must not inherit an enclosing step's `from`).
      # Built on to_h, not Data#with, which requires Ruby 3.3 while the gem
      # supports 3.2.
      def override(**fields)
        self.class.new(**to_h, **fields)
      end

      def to_fields
        {
          execution_key: execution_key,
          transition: transition,
          from: from,
          to: to,
          branch_key: branch_key,
          round: round,
          workflow: workflow
        }.compact
      end
    end

    EMPTY = Context.new(
      execution_key: nil, transition: nil, from: nil, to: nil, branch_key: nil, round: nil, workflow: nil
    )

    class << self
      def current
        Thread.current[THREAD_KEY]
      end

      def ambient
        current || EMPTY
      end

      # The compacted attribution fields, for merging into emitted payloads.
      def current_fields
        context = current
        context ? context.to_fields : {}
      end

      # Plain installation with no restoration: callers own restoration,
      # either through ThreadContextSnapshot (workflow internals) or an
      # enclosing #with / #carrying block.
      def install(context)
        Thread.current[THREAD_KEY] = context
      end

      # Host-facing scope: overlays the ambient attribution for the block.
      def with(**overrides, &block)
        raise ArgumentError, "block required" unless block

        swap(ambient.merge(**overrides), &block)
      end

      # Cross-thread propagation: installs a context captured on another
      # thread (or nil, clearing any stale value on a pooled thread) for the
      # duration of the block.
      def carrying(context, &block)
        raise ArgumentError, "block required" unless block

        swap(context, &block)
      end

      private

      # Matches the gem's scoped thread-state idiom: install and restore run
      # interrupt-deferred, the block itself runs interruptible.
      def swap(context, &block)
        previous = Thread.current[THREAD_KEY]
        Thread.handle_interrupt(Object => :never) do
          Thread.current[THREAD_KEY] = context
          begin
            Thread.handle_interrupt(Object => :immediate, &block)
          ensure
            Thread.current[THREAD_KEY] = previous
          end
        end
      end
    end
  end
end
