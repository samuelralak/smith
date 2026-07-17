# frozen_string_literal: true

require "dry-initializer"

require_relative "../errors"
require_relative "string_snapshot"

module Smith
  class Workflow
    class ExecutionResultSnapshot
      MAX_DEPTH = 128
      MAX_NODES = 100_000
      MAX_BYTES = 4 * 1024 * 1024

      extend Dry::Initializer

      param :value
      option :freeze_copy, default: proc { true }
      option :preserved_error, default: proc {}

      def call
        reset
        root = copy_value(value, depth: 0, preserve_error: true)
        drain
        @containers.each(&:freeze) if freeze_copy
        root
      end

      private

      def reset
        @bytes = 0
        @nodes = 0
        @copies = {}.compare_by_identity
        @containers = []
        @pending = []
      end

      def drain
        until @pending.empty?
          source, copy, depth, preserve_error = @pending.pop
          source.is_a?(Hash) ? copy_hash(source, copy, depth, preserve_error) : copy_array(source, copy, depth)
        end
      end

      def copy_value(item, depth:, preserve_error: false)
        visit!(depth)
        return @copies.fetch(item) if @copies.key?(item)

        case item
        when Hash then prepare_container(item, {}, depth, preserve_error)
        when Array then prepare_container(item, [], depth, false)
        when String then copy_string(item)
        when Float then copy_float(item)
        when Symbol, Integer, true, false, nil then item
        else
          raise WorkflowError,
                "prepared-step execution result contains unsupported mutable value #{item.class}"
        end
      end

      def prepare_container(source, copy, depth, preserve_error)
        @copies[source] = copy
        @containers << copy
        @pending << [source, copy, depth, preserve_error]
        copy
      end

      def copy_hash(source, copy, depth, preserve_error)
        source.each do |key, item|
          copied_key = copy_hash_key(key, depth + 1)
          copied_item = preserved_error?(copied_key, item, preserve_error) ? item : copy_value(item, depth: depth + 1)
          copy[copied_key] = copied_item
        end
      end

      def copy_hash_key(key, depth)
        unless key.is_a?(String) || key.is_a?(Symbol)
          raise WorkflowError,
                "prepared-step execution result contains unsupported Hash key #{key.class}"
        end

        copy_value(key, depth: depth)
      end

      def copy_array(source, copy, depth)
        source.each { |item| copy << copy_value(item, depth: depth + 1) }
      end

      def preserved_error?(key, item, permitted)
        permitted && key == :error && item.equal?(preserved_error)
      end

      def copy_string(string)
        @bytes += StringSnapshot.bytesize(string)
        raise WorkflowError, "prepared-step execution result exceeds maximum bytes #{MAX_BYTES}" if
          @bytes > MAX_BYTES

        StringSnapshot.copy(string, freeze: freeze_copy)
      end

      def copy_float(float)
        return float if float.finite?

        raise WorkflowError, "prepared-step execution result contains non-finite Float"
      end

      def visit!(depth)
        raise WorkflowError, "prepared-step execution result exceeds maximum depth #{MAX_DEPTH}" if depth > MAX_DEPTH

        @nodes += 1
        return if @nodes <= MAX_NODES

        raise WorkflowError, "prepared-step execution result exceeds maximum size #{MAX_NODES}"
      end
    end
  end
end
