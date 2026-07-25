# frozen_string_literal: true

require "dry-struct"

require_relative "../types"

module Smith
  class Tool < RubyLLM::Tool
    class Invocation < Dry::Struct
      OwnedString = Types::String.constructor { |value| value.is_a?(String) ? value.dup.freeze : value }
      private_constant :OwnedString

      attribute :tool_call_id, OwnedString.optional
      attribute :tool_name, OwnedString.constrained(min_size: 1)
      attribute :ordinal, Types::Integer.constrained(gt: 0)
      attribute :batch_ordinal, Types::Integer.constrained(gt: 0)
      attribute :batch_size, Types::Integer.constrained(gt: 0)

      def initialize(...)
        super
        raise ArgumentError, "tool invocation batch ordinal exceeds its batch size" if batch_ordinal > batch_size

        freeze
      end
    end
  end
end
