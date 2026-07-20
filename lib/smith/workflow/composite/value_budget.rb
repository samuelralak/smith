# frozen_string_literal: true

require "dry-initializer"

require_relative "../../errors"
require_relative "../string_snapshot"

module Smith
  class Workflow
    module Composite
      class ValueBudget
        extend Dry::Initializer

        ARRAY_EACH = Array.instance_method(:each)
        HASH_EACH_PAIR = Hash.instance_method(:each_pair)
        private_constant :ARRAY_EACH, :HASH_EACH_PAIR

        option :max_bytes
        option :max_nodes
        option :max_depth
        option :label

        def initialize(...)
          super
          @bytes = 0
          @nodes = 0
        end

        def add(value, depth: 0)
          pending = [[value, depth]]
          until pending.empty?
            item, item_depth = pending.pop
            visit!(item, item_depth, pending)
          end
          self
        end

        private

        def visit!(item, depth, pending)
          validate_visit!(depth)
          dispatch_value(item, depth, pending)
        end

        def dispatch_value(item, depth, pending)
          case item
          when Hash then enqueue_hash(item, depth, pending)
          when Array then enqueue_array(item, depth, pending)
          when String, Symbol then add_bytes!(item.to_s)
          when Float then validate_float!(item)
          when Integer, true, false, nil then nil
          else raise WorkflowError, "#{label} contains unsupported value #{item.class}"
          end
        end

        def validate_visit!(depth)
          raise WorkflowError, "#{label} exceeds maximum depth #{max_depth}" if depth > max_depth

          @nodes += 1
          raise WorkflowError, "#{label} exceeds maximum size #{max_nodes}" if @nodes > max_nodes
        end

        def enqueue_hash(hash, depth, pending)
          HASH_EACH_PAIR.bind_call(hash) do |key, value|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise WorkflowError, "#{label} contains unsupported Hash key #{key.class}"
            end

            pending << [value, depth + 1] << [key, depth + 1]
          end
        end

        def enqueue_array(array, depth, pending)
          ARRAY_EACH.bind_call(array) { |value| pending << [value, depth + 1] }
        end

        def add_bytes!(string)
          @bytes += StringSnapshot.bytesize(string)
          raise WorkflowError, "#{label} exceeds maximum bytes #{max_bytes}" if @bytes > max_bytes
        end

        def validate_float!(float)
          return if float.finite?

          raise WorkflowError, "#{label} contains a non-finite Float"
        end
      end
    end
  end
end
