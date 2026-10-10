# frozen_string_literal: true

require "digest"
require "json"

module Smith
  # Keys for requests a step sends outside the system, so that a replay of
  # the step (a retry, or a restore after a crash) repeats each request
  # under the key it used before and the receiver can drop the duplicate.
  #
  # A key is the SHA-256 of the run's execution namespace (a UUID assigned
  # when the workflow is built and persisted with it), the step's position
  # (step number and transition, then any nested workflow step, parallel or
  # fan-out branch, optimizer round or orchestrator task inside it) and a
  # caller-chosen scope. It is the same on every attempt of the step, so a
  # retry after a timeout cannot repeat a request that took effect, and
  # after a restore. An attempt that fails in a way showing its request
  # took no effect can ask for a new key on the next attempt (`fail!` with
  # `new_idempotency_key: true`, or `retry_on ... new_idempotency_key_on:`),
  # for receivers that store a failed reply under its key. Keys differ
  # between runs, even two runs persisted under the same persistence key
  # one after the other. A replay keeps its keys only when the run was
  # persisted before the step began, as `advance_persisted!` and
  # `run_persisted!` do.
  #
  #   transition :notify, from: :reviewed, to: :notified do
  #     compute { |step| Mailer.deliver(review, idempotency_key: step.idempotency_key) }
  #   end
  module IdempotencyKey
    VERSION = "smith.idempotency.v1"
    MAX_SCOPE_DEPTH = 32

    # Where execution is: the run's namespace and the path of positions
    # inside it. Immutable; `within` returns a narrower scope.
    Scope = Data.define(:run, :path) do
      def self.root(run) = new(run: run.dup.freeze, path: [].freeze)

      def within(*segment) = self.class.new(run:, path: [*path, segment.freeze].freeze)

      def key(scope = nil)
        Digest::SHA256.hexdigest(JSON.generate([VERSION, run, path, IdempotencyKey.canonical(scope)]))
      end
    end

    module_function

    # The key for `scope` at the current position. Raises WorkflowError
    # outside a running workflow step.
    def current(scope = nil)
      current_scope!.key(scope)
    end

    def current_scope
      Tool.__send__(:current_idempotency_scope)
    end

    def current_scope!
      current_scope || raise(WorkflowError, "an idempotency key is only available inside a running workflow step")
    end

    # Narrows the current position for the block, when there is one.
    # Interrupts are deferred while the scope is installed and restored,
    # as for every other per-step thread value.
    def within(*segment, &block)
      raise ArgumentError, "block required" unless block

      outer = current_scope
      return yield unless outer

      Thread.handle_interrupt(Object => :never) do
        install(outer.within(*segment))
        begin
          Thread.handle_interrupt(Object => :immediate, &block)
        ensure
          install(outer)
        end
      end
    end

    def install(scope)
      Tool.__send__(:current_idempotency_scope=, scope)
    end

    # The JSON form a scope is hashed in: Symbols become Strings and Hash
    # entries are sorted by key, so equal scopes give equal keys whatever
    # their key order. Floats and other objects are refused, because their
    # text form is not a stable identity.
    def canonical(value, depth = 0)
      raise ArgumentError, "idempotency key scope is nested deeper than #{MAX_SCOPE_DEPTH} levels" if too_deep?(depth)

      case value
      when nil, true, false, Integer then value
      when String, Symbol then canonical_string(value.to_s)
      when Array then value.map { |item| canonical(item, depth + 1) }
      when Hash then canonical_hash(value, depth)
      else
        raise ArgumentError,
              "idempotency key scope must be built from Strings, Symbols, Integers, booleans, nil, Arrays " \
              "and Hashes, got #{DiagnosticText.error_class_name(value)}"
      end
    end

    def too_deep?(depth) = depth > MAX_SCOPE_DEPTH

    def canonical_hash(hash, depth)
      entries = hash.map { |key, value| [canonical_hash_key(key), canonical(value, depth + 1)] }
      keys = entries.map(&:first)
      raise ArgumentError, "idempotency key scope has two keys with the same name" unless keys.uniq.size == keys.size

      entries.sort_by(&:first).to_h
    end

    def canonical_hash_key(key)
      return canonical_string(key.to_s) if key.is_a?(String) || key.is_a?(Symbol)

      raise ArgumentError, "idempotency key scope Hash keys must be Strings or Symbols"
    end

    def canonical_string(string)
      utf8 = string.encoding == Encoding::UTF_8 ? string : string.encode(Encoding::UTF_8)
      return utf8 if utf8.valid_encoding?

      raise EncodingError
    rescue EncodingError
      raise ArgumentError, "idempotency key scope Strings must be valid UTF-8 or convert to it"
    end
  end
end
