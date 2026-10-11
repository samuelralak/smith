# frozen_string_literal: true

module Smith
  module Batch
    # Whether a succeeded result's message has the shape of an Anthropic
    # Messages reply, as the provider's parser reads it: `content` an Array of
    # blocks, each a Hash with a String `type` (a text block's `text` a
    # String), and `usage` a Hash whose token counts are non-negative
    # Integers. Anything else is refused before the step runs.
    module MessageShape
      COUNTS = %w[input_tokens output_tokens].freeze
      OPTIONAL_COUNTS = %w[cache_read_input_tokens cache_creation_input_tokens].freeze
      private_constant :COUNTS, :OPTIONAL_COUNTS

      module_function

      def valid?(message)
        message.is_a?(Hash) && message["content"].is_a?(Array) && message["content"].all? { block?(_1) } &&
          usage?(message["usage"])
      end

      def block?(block)
        return false unless block.is_a?(Hash) && block["type"].is_a?(String)

        block["type"] != "text" || block["text"].is_a?(String)
      end

      def usage?(usage)
        usage.is_a?(Hash) && COUNTS.all? { count?(usage[_1]) } &&
          OPTIONAL_COUNTS.all? { usage[_1].nil? || count?(usage[_1]) }
      end

      def count?(value) = value.is_a?(Integer) && !value.negative?
    end
  end
end
