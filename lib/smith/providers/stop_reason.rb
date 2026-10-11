# frozen_string_literal: true

module Smith
  module Providers
    # What a provider's stop reason says about how a response ended: cut off
    # at the output limit (:truncated), declined (:refused), or nothing Smith
    # acts on (nil, which includes an absent or unknown stop reason).
    #
    #   truncated  max_tokens, model_context_window_exceeded (Anthropic,
    #              Bedrock), length (OpenAI Chat Completions),
    #              max_output_tokens (OpenAI Responses), MAX_TOKENS (Gemini),
    #              output_limit_reached (Smith, for a streamed reply whose
    #              stop reason was not read and whose output reached the
    #              request's limit)
    #   refused    refusal (Anthropic; OpenAI's message-level refusal),
    #              prompt_blocked (a Gemini prompt block),
    #              content_filter (OpenAI), SAFETY, RECITATION, BLOCKLIST,
    #              PROHIBITED_CONTENT, SPII, IMAGE_SAFETY (Gemini),
    #              content_filtered, guardrail_intervened (Bedrock)
    module StopReason
      TRUNCATED = %w[
        max_tokens model_context_window_exceeded length max_output_tokens MAX_TOKENS output_limit_reached
      ].freeze
      REFUSED = %w[
        refusal prompt_blocked content_filter SAFETY RECITATION BLOCKLIST PROHIBITED_CONTENT SPII IMAGE_SAFETY
        content_filtered guardrail_intervened
      ].freeze

      module_function

      def classify(stop_reason)
        return :truncated if TRUNCATED.include?(stop_reason)

        :refused if REFUSED.include?(stop_reason)
      end
    end
  end
end
