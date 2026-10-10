# frozen_string_literal: true

require_relative "../diagnostic_text"

module Smith
  class Workflow
    # The one shape a workflow context has everywhere: top-level keys are
    # Symbols, and every Hash key inside a value is the Symbol of its String
    # form, which is exactly what a JSON checkpoint and restore produce, so a
    # key reads the same live and after a round trip. Values are not
    # converted; only JSON-native values (Strings, numbers, booleans, nil,
    # Hashes, Arrays) round-trip unchanged.
    module ContextKeys
      # JSON's own default nesting limit: a deeper context could not be
      # checkpointed anyway.
      MAX_DEPTH = 100

      module_function

      # A context given to `Workflow.new` or to a class-level helper that
      # derives a persistence key from it. Top-level keys must already be
      # Symbols, the rule `write_context` applies to every key it writes.
      def normalize_context(context)
        raise WorkflowError, "workflow context must be a Hash, got #{context.class}" unless context.is_a?(Hash)

        context.each_key { |key| validate_top_level_key!(key) }
        normalize(context)
      end

      def validate_top_level_key!(key)
        return if key.is_a?(Symbol)

        raise WorkflowError,
              "workflow context keys must be Symbols, got #{bounded(key.inspect)} (#{key.class}); " \
              "convert them before building the workflow"
      end

      # A copy of `value` with every Hash key at every depth turned into the
      # Symbol of its String form. Raises WorkflowError when two keys of one
      # Hash become the same Symbol, when a container contains itself, or
      # past MAX_DEPTH. `O(N)` in the number of Hash entries and Array
      # elements.
      def normalize(value, path = {}.compare_by_identity, depth = 0)
        case value
        when Hash then within(value, path, depth) { normalize_hash(value, path, depth) }
        when Array then within(value, path, depth) { value.map { |item| normalize(item, path, depth + 1) } }
        else value
        end
      end

      def normalize_hash(hash, path, depth)
        hash.each_with_object({}) do |(key, nested), normalized|
          symbol = key.is_a?(Symbol) ? key : key.to_s.to_sym
          if normalized.key?(symbol)
            raise WorkflowError, "workflow context has two keys that both become #{bounded(symbol.inspect)}"
          end

          normalized[symbol] = normalize(nested, path, depth + 1)
        end
      end

      def within(container, path, depth)
        raise WorkflowError, "workflow context is nested deeper than #{MAX_DEPTH} levels" if depth > MAX_DEPTH
        raise WorkflowError, "workflow context contains itself" if path.key?(container)

        path[container] = true
        begin
          yield
        ensure
          path.delete(container)
        end
      end

      def bounded(text) = DiagnosticText.capture(text, max_bytes: 256)
    end
  end
end
