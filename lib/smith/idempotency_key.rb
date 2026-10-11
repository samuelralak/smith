# frozen_string_literal: true

require "digest"
require "json"

require_relative "idempotency_key/canonical"

module Smith
  # Keys for requests a step sends outside the system, so that a replay of
  # the step (a retry, or a restore after a crash) repeats each request
  # under the key it used before and the receiver can drop the duplicate.
  #
  # A key is the SHA-256 of the run's execution namespace (a UUID assigned
  # when the workflow is built and persisted with it), the step's position
  # (step number and transition, then any nested workflow step, parallel or
  # fan-out branch, optimizer round and role, or orchestrator round and
  # task inside it) and a caller-chosen scope. It is the same on every
  # attempt of the step, so a retry after a timeout cannot repeat a request
  # that took effect, and after a restore. An attempt of a step that fails
  # in a way showing its own requests took no effect can ask for new keys
  # on the attempts after it (`fail!` with `new_idempotency_key: true`, or
  # `retry_on ... new_idempotency_key_on:`), for receivers that store a
  # failed reply under its key. A replay keeps its keys only when the run
  # was persisted before the step began, as `advance_persisted!` and
  # `run_persisted!` do. A persisted payload is a run's identity: runs
  # built with `new` never share keys, but runs restored from copies of one
  # payload do.
  #
  # Keys exist only while a step does its own work (its body, agents,
  # tools and guardrails); event handlers and `on_step` callbacks get none.
  # The position is thread-local state Smith carries into its own branch
  # threads and concurrent tool calls; code in a Fiber or Thread the host
  # creates has none, while `step.idempotency_key` works anywhere.
  #
  #   transition :notify, from: :reviewed, to: :notified do
  #     compute { |step| Mailer.deliver(review, idempotency_key: step.idempotency_key) }
  #   end
  module IdempotencyKey
    VERSION = "smith.idempotency.v1"

    # Where execution is: the run's namespace and the path of positions
    # inside it, deeply frozen. Internal: hosts reach keys through
    # `current`, `step.idempotency_key` and `Tool#idempotency_key`.
    Scope = Data.define(:run, :path) do
      def within(*segment)
        self.class.new(run:, path: [*path, IdempotencyKey.__send__(:own_segment, segment)].freeze)
      end

      def key(scope = nil)
        Digest::SHA256.hexdigest(JSON.generate([VERSION, run, path, Canonical.value(scope)]))
      end
    end
    private_constant :Scope

    class << self
      # The key for `scope` at the current position. Raises WorkflowError
      # outside a running workflow step.
      def current(scope = nil)
        current_scope!.key(scope)
      end

      private

      def root_scope(run) = Scope.new(run: run.dup.freeze, path: [].freeze)

      def current_scope
        Tool.__send__(:current_idempotency_scope)
      end

      def current_scope!
        current_scope || raise(WorkflowError, "an idempotency key is only available inside a running workflow step")
      end

      # Narrows the current position for the block, when there is one.
      def within(*segment, &)
        outer = current_scope
        return yield unless outer

        swap(outer.within(*segment), &)
      end

      # Runs the block with no position, so code that is not a step's own
      # work (event handlers, callbacks) cannot take a step's key.
      def without(&) = swap(nil, &)

      # Interrupts are deferred while the position is installed and
      # restored, as for every other per-step thread value.
      def swap(scope, &block)
        raise ArgumentError, "block required" unless block

        outer = current_scope
        Thread.handle_interrupt(Object => :never) do
          install(scope)
          begin
            Thread.handle_interrupt(Object => :immediate, &block)
          ensure
            install(outer)
          end
        end
      end

      def install(scope)
        raise ArgumentError, "an idempotency position must be a Scope or nil" unless scope.nil? || scope.is_a?(Scope)

        Tool.__send__(:current_idempotency_scope=, scope)
      end

      # A namespace for a payload written before namespaces were assigned at
      # construction: derived from the payload's own durable facts, so every
      # restore of it gets the same one, and shaped as the version 4 UUID
      # `new` assigns.
      def legacy_namespace(*facts)
        hex = Digest::SHA256.hexdigest(JSON.generate([VERSION, "namespace", *facts.map(&:to_s)]))
        variant = ((hex[16].to_i(16) & 0x3) | 0x8).to_s(16)
        "#{hex[0, 8]}-#{hex[8, 4]}-4#{hex[13, 3]}-#{variant}#{hex[17, 3]}-#{hex[20, 12]}"
      end

      # A position segment: a label and Strings, Symbols or Integers, held
      # as frozen copies so a caller cannot change a key after the fact.
      def own_segment(segment)
        segment.map do |part|
          case part
          when Integer then part
          when Symbol then part.to_s.freeze
          when String then Canonical.string(part).dup.freeze
          else raise ArgumentError, "an idempotency position segment must be Strings, Symbols or Integers"
          end
        end.freeze
      end

      # Narrows the position to the `count`th copy of `value` seen under
      # `label`, named by its content: a list a model regenerates on replay
      # keeps each item's key whatever its order.
      def within_content(label, value, copies, &)
        digest = content_digest(value)
        copies[digest] += 1
        within(label, digest, copies[digest], &)
      end

      # A digest of a value's canonical form, for a position named by its
      # content (an orchestrator task) rather than by its place in a list.
      def content_digest(value) = Digest::SHA256.hexdigest(JSON.generate(Canonical.value(value)))
    end
  end
end
