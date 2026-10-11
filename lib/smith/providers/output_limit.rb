# frozen_string_literal: true

module Smith
  module Providers
    # A provider's own parameter for the most tokens a response may hold,
    # merged into the request when an agent retries a cut-off response
    # (`on_truncation retry_with: { max_tokens: n }`). A provider not listed
    # here is not retried.
    module OutputLimit
      PROVIDERS = %w[anthropic openai gemini vertexai bedrock].freeze

      module_function

      def supported?(provider) = PROVIDERS.include?(provider.to_s)

      # `chat_params` tells the OpenAI paths apart: Smith routes a chat
      # whose params carry `openai_api_mode: :responses` to the Responses
      # API.
      def params(provider, chat_params, max_tokens)
        case provider.to_s
        when "anthropic" then { max_tokens: }
        when "openai"
          responses?(chat_params) ? { max_output_tokens: max_tokens } : { max_completion_tokens: max_tokens }
        when "gemini", "vertexai" then { generationConfig: { maxOutputTokens: max_tokens } }
        when "bedrock" then { inferenceConfig: { maxTokens: max_tokens } }
        end
      end

      def responses?(chat_params)
        params = chat_params.is_a?(Hash) ? chat_params : {}
        (params[:openai_api_mode] || params["openai_api_mode"]).to_s == "responses"
      end
    end
  end
end
