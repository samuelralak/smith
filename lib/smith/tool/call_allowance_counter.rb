# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class CallAllowanceCounter
      def initialize(budget)
        @budget = budget
        @remaining = budget.total
        @remaining_by_tool = budget.tool_limits&.dup
      end

      attr_reader :remaining

      def remaining_for(tool_name)
        @remaining_by_tool.fetch(tool_name, 0)
      end

      def used?
        remaining < @budget.total
      end

      def available?(batch)
        remaining >= batch.size && tool_counts_available?(batch.counts)
      end

      def consume!(batch)
        @remaining -= batch.size
        return unless @budget.exact?

        batch.counts.each { |name, count| @remaining_by_tool[name] -= count }
      end

      private

      def tool_counts_available?(counts)
        return true unless @budget.exact?
        return false unless counts

        counts.all? { |name, count| @remaining_by_tool.fetch(name, 0) >= count }
      end
    end
  end
end
