# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class CallBatch
      attr_reader :size, :counts

      def self.coerce(value, exact:)
        return from_size(value, exact:) if value.is_a?(Integer)
        raise ArgumentError, "tool call batch size must be a positive integer" unless value.is_a?(Array)

        names = value.map { canonical_tool_name(_1) }
        validate_size!(names.length)
        new(size: names.length, counts: names.tally.freeze)
      end

      def self.from_size(size, exact:)
        validate_size!(size)
        raise ArgumentError, "exact tool call allowance requires tool names for batch reservation" if exact

        new(size:, counts: nil)
      end
      private_class_method :from_size

      def self.canonical_tool_name(value)
        name = value.to_s
        raise ArgumentError, "tool name must not be empty" if name.empty?

        name
      end
      private_class_method :canonical_tool_name

      def self.validate_size!(size)
        return if size.is_a?(Integer) && size.positive?

        raise ArgumentError, "tool call batch size must be a positive integer"
      end
      private_class_method :validate_size!

      def initialize(size:, counts:)
        @size = size
        @counts = counts
        freeze
      end
    end
  end
end
