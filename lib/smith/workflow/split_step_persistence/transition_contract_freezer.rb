# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    module SplitStepPersistence
      class TransitionContractFreezer
        extend Dry::Initializer

        CORE_FREEZE = Object.instance_method(:freeze)

        option :value
        option :max_depth
        option :max_nodes

        def call
          stack = [[value, 0]]
          seen = {}.compare_by_identity
          nodes = 0
          until stack.empty?
            item, depth = stack.pop
            nodes = visit!(nodes, depth)
            freeze_item(item, depth, stack, seen)
          end
          value
        end

        private

        def visit!(nodes, depth)
          raise WorkflowError, "split-step transition contract exceeds maximum depth #{max_depth}" if depth > max_depth
          return nodes + 1 if nodes < max_nodes

          raise WorkflowError, "split-step transition contract exceeds maximum size #{max_nodes}"
        end

        def freeze_item(item, depth, stack, seen)
          return if immutable?(item) || item.is_a?(Module) || seen.key?(item)

          seen[item] = true
          children(item).reverse_each { |child| stack << [child, depth + 1] }
          CORE_FREEZE.bind_call(item)
        end

        def children(item)
          return [] if leaf?(item)
          return item.flat_map { |key, value| [key, value] } if item.is_a?(Hash)
          return [item.begin, item.end] if item.is_a?(Range)

          object_children(item)
        end

        def object_children(item)
          return item.to_a if item.is_a?(Array) || item.is_a?(Set)
          return member_children(item) if item.is_a?(Struct) || item.is_a?(Data)

          transition_children(item)
        end

        def member_children(item)
          item.members.map { |name| item.public_send(name) }
        end

        def transition_children(item)
          unless item.is_a?(Workflow::Transition)
            raise WorkflowError, "split-step transition contract contains unsupported value #{item.class}"
          end

          item.instance_variables.map { |name| item.instance_variable_get(name) }
        end

        def leaf?(item)
          item.is_a?(String) || item.is_a?(Proc)
        end

        def immutable?(item)
          item.nil? || item.is_a?(Symbol) || item.is_a?(Numeric) || item == true || item == false
        end
      end
    end
  end
end
