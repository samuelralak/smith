# frozen_string_literal: true

module Smith
  class Workflow
    # rubocop:disable Style/RedundantStructKeywordInit
    # `input_tokens` counts uncached input; `cache_read_tokens` and
    # `cache_write_tokens` are the prompt-cache input beside it, and
    # `total_tokens` adds all three to the output. `mode` is how the call was
    # made (`:sync` unless a streaming or batch step says otherwise).
    AgentResult = Struct.new(
      :content, :input_tokens, :output_tokens, :cost, :model_used, :provider_used,
      :cache_read_tokens, :cache_write_tokens, :thinking_tokens, :stop_reason, :provider_message_id, :mode,
      keyword_init: true
    ) do
      # The detail members of an AgentResult taken from a ProviderUsage.
      def self.usage_details(usage)
        return {} unless usage

        self::USAGE_DETAIL_MEMBERS.to_h do |member|
          [member, usage.respond_to?(member) ? usage.public_send(member) : nil]
        end
      end

      def self.from_response(response, content, model_used: nil, provider_used: nil)
        new(
          content: content,
          input_tokens: response.respond_to?(:input_tokens) ? response.input_tokens : nil,
          output_tokens: response.respond_to?(:output_tokens) ? response.output_tokens : nil,
          cost: nil,
          model_used: model_used,
          provider_used: provider_used
        )
      end

      def usage_known?
        !input_tokens.nil? && !output_tokens.nil?
      end

      def total_tokens
        return unless usage_known?

        input_tokens + output_tokens + (cache_read_tokens || 0) + (cache_write_tokens || 0)
      end
    end
    AgentResult::USAGE_DETAIL_MEMBERS = %i[
      cache_read_tokens cache_write_tokens thinking_tokens stop_reason provider_message_id
    ].freeze
    # rubocop:enable Style/RedundantStructKeywordInit
  end
end
