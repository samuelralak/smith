# frozen_string_literal: true

module Smith
  class Workflow
    # rubocop:disable Style/RedundantStructKeywordInit
    AgentResult = Struct.new(
      :content, :input_tokens, :output_tokens, :cost, :model_used,
      keyword_init: true
    ) do
      def self.from_response(response, content, model_used: nil)
        new(
          content: content,
          input_tokens: response.respond_to?(:input_tokens) ? response.input_tokens : nil,
          output_tokens: response.respond_to?(:output_tokens) ? response.output_tokens : nil,
          cost: nil,
          model_used: model_used
        )
      end

      def usage_known?
        !input_tokens.nil? && !output_tokens.nil?
      end
    end
    # rubocop:enable Style/RedundantStructKeywordInit
  end
end
