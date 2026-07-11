# frozen_string_literal: true

require "dry-initializer"
require "digest"

module Smith
  class Workflow
    module SplitStepPersistence
      class TransitionContractSignature
        extend Dry::Initializer
        include TransitionContractStructuredValues

        option :value
        option :max_depth
        option :max_nodes
        option :max_bytes

        def call
          @nodes = 0
          @bytes = 0
          @seen = {}.compare_by_identity
          signature_value(value, 0)
        end

        private

        def signature_value(item, depth)
          visit!(depth)
          reference = reference_for(item)
          return reference if reference
          return terminal_signature(item) if terminal?(item)

          composite_signature(item, depth)
        end

        def composite_signature(item, depth)
          case item
          when Hash then hash_signature(item, depth)
          when Array then collection_signature(:array, item, depth)
          when Set then collection_signature(:set, item, depth)
          else structured_signature(item, depth)
          end
        end

        def terminal_signature(item)
          case item
          when String then string_signature(item)
          when Module then [:module, item.name, item.object_id]
          when Proc then proc_signature(item)
          else item
          end
        end

        def hash_signature(hash, depth)
          [:hash, reference_id(hash), hash.map do |key, item|
            [signature_value(key, depth + 1), signature_value(item, depth + 1)]
          end]
        end

        def collection_signature(kind, collection, depth)
          [kind, reference_id(collection), collection.map { |item| signature_value(item, depth + 1) }]
        end

        def proc_signature(callable)
          [:proc, callable.object_id, callable.source_location, callable.parameters, callable.lambda?]
        end

        def string_signature(string)
          @bytes += string.bytesize
          raise WorkflowError, "split-step transition contract exceeds maximum bytes #{max_bytes}" if @bytes > max_bytes

          [:string, string.bytesize, Digest::SHA256.hexdigest(string)]
        end

        def reference_for(item)
          return unless referenceable?(item)
          return [:reference, reference_id(item)] if @seen.key?(item)

          @seen[item] = @seen.size
          nil
        end

        def reference_id(item) = @seen.fetch(item)

        def referenceable?(item)
          !terminal?(item)
        end

        def terminal?(item)
          case item
          when String, Symbol, Numeric, Module, Proc, true, false, nil then true
          else false
          end
        end

        def visit!(depth)
          raise WorkflowError, "split-step transition contract exceeds maximum depth #{max_depth}" if depth > max_depth

          @nodes += 1
          return if @nodes <= max_nodes

          raise WorkflowError, "split-step transition contract exceeds maximum size #{max_nodes}"
        end
      end
    end
  end
end
