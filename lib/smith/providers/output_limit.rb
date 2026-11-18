# frozen_string_literal: true

module Smith
  module Providers
    # A provider's own parameter for the most tokens a response may hold,
    # merged into the request when an agent retries a cut-off response
    # (`on_truncation retry_with: { max_tokens: n }`). A provider not listed
    # here is not retried. An agent's own cap (`params max_tokens:`) goes to
    # an OpenAI model that reasons under the name it takes on every attempt
    # (`named`): its Chat Completions refuses `max_tokens` from those models.
    module OutputLimit
      PROVIDERS = %w[anthropic openai gemini vertexai bedrock].freeze
      PARAM_PATHS = {
        "anthropic" => [%i[max_tokens]],
        "openai" => [%i[max_output_tokens], %i[max_completion_tokens], %i[max_tokens]],
        "gemini" => [%i[generationConfig maxOutputTokens]],
        "vertexai" => [%i[generationConfig maxOutputTokens]],
        "bedrock" => [%i[inferenceConfig maxTokens]]
      }.freeze
      ANTHROPIC_DEFAULT = 4096

      module_function

      def supported?(provider) = PROVIDERS.include?(provider.to_s)

      # `chat_params` tells the OpenAI paths apart: Smith routes a chat
      # whose params carry `openai_api_mode: :responses` to the Responses
      # API, and a chat that already sets the older `max_tokens` keeps it.
      def params(provider, chat_params, max_tokens)
        case provider.to_s
        when "anthropic" then { max_tokens: }
        when "openai" then { openai_key(chat_params) => max_tokens }
        when "gemini", "vertexai" then { generationConfig: { maxOutputTokens: max_tokens } }
        when "bedrock" then { inferenceConfig: { maxTokens: max_tokens } }
        end
      end

      # The limit a request already had: the agent's own parameter, else for
      # Anthropic the model's maximum as RubyLLM sends it; nil when unknown.
      def current(provider, chat_params, model_reference)
        set = PARAM_PATHS.fetch(provider.to_s, []).filter_map { |path| lookup(chat_params, path) }.first
        return set if set.is_a?(Integer)

        anthropic_default(model_reference.model_id) if provider.to_s == "anthropic"
      end

      # The params with the cap of a request to an OpenAI model that reasons
      # under the name its path takes (`max_completion_tokens`, or
      # `max_output_tokens` on the Responses API); any other request, an
      # OpenAI-compatible server's `max_tokens` among them, unchanged.
      def named(provider, chat_params, model_reference)
        limit = provider.to_s == "openai" && reasons?(model_reference) ? current("openai", chat_params, nil) : nil
        return chat_params unless limit.is_a?(Integer)

        caps = PARAM_PATHS.fetch("openai").flatten.flat_map { |key| [key, key.to_s] }
        unnamed = chat_params.except(*caps)
        unnamed.merge(params("openai", unnamed, limit))
      end

      def reasons?(model_reference)
        ::RubyLLM.models.find(model_reference.model_id.to_s, "openai").capabilities.include?("reasoning")
      rescue ::RubyLLM::ModelNotFoundError
        false
      end

      def openai_key(chat_params)
        return :max_output_tokens if responses?(chat_params)

        lookup(chat_params, %i[max_tokens]) ? :max_tokens : :max_completion_tokens
      end

      def responses?(chat_params) = lookup(chat_params, %i[openai_api_mode]).to_s == "responses"

      def lookup(params, path)
        path.reduce(params) do |level, key|
          break unless level.is_a?(Hash)

          level.key?(key) ? level[key] : level[key.to_s]
        end
      end

      def anthropic_default(model_id)
        ::RubyLLM.models.find(model_id.to_s, "anthropic").max_tokens || ANTHROPIC_DEFAULT
      rescue StandardError
        ANTHROPIC_DEFAULT
      end
    end
  end
end
