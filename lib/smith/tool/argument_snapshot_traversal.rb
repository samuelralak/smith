# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Tool < RubyLLM::Tool
    class ArgumentSnapshotTraversal
      MAX_DEPTH = 100
      MAX_NODES = 100_000
      MAX_BYTES = 1 * 1024 * 1024

      extend Dry::Initializer

      param :value

      def call
        initialize_traversal
        result = copy
        ArgumentSnapshotResult.new(
          value: result,
          node_count: @accounting.node_count,
          byte_count: @accounting.byte_count
        )
      end

      private

      def initialize_traversal
        @active = {}.compare_by_identity
        @copies = {}.compare_by_identity
        @metrics = {}.compare_by_identity
        @accounting = ArgumentSnapshotAccounting.new(
          max_depth: MAX_DEPTH,
          max_nodes: MAX_NODES,
          max_bytes: MAX_BYTES
        )
        @scalar_snapshot = ArgumentScalarSnapshot.new(
          byte_counter: @accounting.method(:add_bytes!),
          byte_validator: @accounting.method(:validate_bytes!)
        )
        @container_reader = ArgumentContainerReader.new(
          scalar_snapshot: @scalar_snapshot,
          byte_count: -> { @accounting.byte_count }
        )
      end

      def copy
        result = nil
        pending = [[:visit, value, nil, nil, 0, nil]]

        until pending.empty?
          entry = pending.pop
          if entry.first == :finish
            finish_container!(entry)
            next
          end

          _, source, parent, key, depth, parent_metrics = entry
          @accounting.visit!(depth)
          type = @container_reader.type(source)
          copied = if type
                     copy_container(source, pending, depth, type, parent_metrics)
                   else
                     copy_scalar(source, parent_metrics)
                   end
          parent ? parent[key] = copied : result = copied
        end

        result
      end

      def copy_container(source, pending, depth, type, parent_metrics)
        raise Error, "tool arguments contain a cyclic value" if @active.key?(source)
        return copy_reused_container(source, depth, parent_metrics) if @copies.key?(source)

        size = @container_reader.size(source, type)
        @accounting.reserve_children!(size)
        captured = @container_reader.snapshot(source, type)
        unless @container_reader.size(captured, type) == size
          raise Error, "tool argument container changed while it was being captured"
        end

        target = @container_reader.target(type, size)
        metrics = { node_count: 1, byte_count: 0, max_depth: 0 }
        @copies[source] = target
        @active[source] = true
        pending << [:finish, source, target, parent_metrics, metrics]
        @container_reader.append_children(pending:, source: captured, target:, depth:, metrics:)
        target
      end

      def finish_container!(entry)
        _, source, target, parent_metrics, metrics = entry
        @active.delete(source)
        target.freeze
        @metrics[source] = metrics.freeze
        @accounting.propagate!(parent_metrics, metrics)
      end

      def copy_reused_container(source, depth, parent_metrics)
        metrics = @metrics.fetch(source)
        @accounting.account_reused!(metrics, depth)
        @accounting.propagate!(parent_metrics, metrics)
        @copies.fetch(source)
      end

      def copy_scalar(source, parent_metrics)
        previous_bytes = @accounting.byte_count
        copied = @scalar_snapshot.copy(source)
        if parent_metrics
          parent_metrics[:node_count] += 1
          parent_metrics[:byte_count] += @accounting.byte_count - previous_bytes
          parent_metrics[:max_depth] = [parent_metrics[:max_depth], 1].max
        end
        copied
      end
    end
  end
end
