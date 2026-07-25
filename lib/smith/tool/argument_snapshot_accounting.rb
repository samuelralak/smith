# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Tool < RubyLLM::Tool
    class ArgumentSnapshotAccounting
      extend Dry::Initializer

      option :max_depth
      option :max_nodes
      option :max_bytes

      attr_reader :node_count, :byte_count

      def initialize(...)
        super
        @node_count = 0
        @allocated_node_count = 1
        @byte_count = 0
      end

      def visit!(depth)
        raise Error, "tool arguments exceed #{max_depth} levels" if depth > max_depth

        add_nodes!(1)
      end

      def reserve_children!(count)
        @allocated_node_count += count
        raise Error, "tool arguments exceed #{max_nodes} values" if @allocated_node_count > max_nodes
      end

      def add_bytes!(bytes)
        @byte_count += bytes
        raise Error, "tool arguments exceed #{max_bytes} bytes" if @byte_count > max_bytes
      end

      def validate_bytes!(bytes)
        raise Error, "tool arguments exceed #{max_bytes} bytes" if @byte_count + bytes > max_bytes
      end

      def account_reused!(metrics, depth)
        raise Error, "tool arguments exceed #{max_depth} levels" if depth + metrics.fetch(:max_depth) > max_depth

        add_nodes!(metrics.fetch(:node_count) - 1)
        add_bytes!(metrics.fetch(:byte_count))
      end

      def propagate!(parent_metrics, child_metrics)
        return unless parent_metrics

        parent_metrics[:node_count] += child_metrics.fetch(:node_count)
        parent_metrics[:byte_count] += child_metrics.fetch(:byte_count)
        parent_metrics[:max_depth] = [
          parent_metrics[:max_depth],
          child_metrics.fetch(:max_depth) + 1
        ].max
      end

      private

      def add_nodes!(count)
        @node_count += count
        raise Error, "tool arguments exceed #{max_nodes} values" if @node_count > max_nodes
      end
    end
  end
end
