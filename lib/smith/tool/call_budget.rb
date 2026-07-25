# frozen_string_literal: true

require "dry-struct"

require_relative "../types"

module Smith
  class Tool < RubyLLM::Tool
    class CallBudget < Dry::Struct
      OwnedString = Types::String.constructor { |value| value.is_a?(String) ? value.dup.freeze : value }
      ToolName = OwnedString.constrained(min_size: 1)
      Limit = Types::Integer.constrained(gteq: 0)
      PositiveLimit = Types::Integer.constrained(gt: 0)
      ToolLimits = Types::Hash.map(ToolName, PositiveLimit)

      private_constant :OwnedString, :ToolName, :Limit, :PositiveLimit, :ToolLimits

      attribute :total, Limit
      attribute :tool_limits, ToolLimits.optional.default(nil)

      def self.coerce(value)
        return value if value.is_a?(self)
        return new(total: value) if value.is_a?(Integer)

        raise ArgumentError, "tool call budget must be an integer or Smith::Tool::CallBudget"
      end

      def initialize(...)
        super
        validate_tool_limits!
        tool_limits&.freeze
        freeze
      end

      def exact? = !tool_limits.nil?

      def limit_for(tool_name)
        tool_limits&.fetch(tool_name.to_s, nil)
      end

      private

      def validate_tool_limits!
        return unless tool_limits
        return if total <= tool_limits.values.sum

        raise ArgumentError, "aggregate tool call allowance exceeds the sum of its per-tool limits"
      end
    end
  end
end
