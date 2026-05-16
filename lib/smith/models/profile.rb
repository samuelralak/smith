# frozen_string_literal: true

module Smith
  module Models
    # Immutable capability record for a model id. Holds only inherent
    # provider/model properties — never pricing, never API keys, never
    # request-specific data. Library-shipped rules live in
    # Smith::Models::Inference (pattern-based).
    #
    # Fields:
    #   model_id                   — canonical id ("claude-opus-4-7")
    #   provider                   — :anthropic | :openai | :gemini | :xai | ...
    #   thinking_shape             — nil | :budget_tokens | :reasoning_effort | :adaptive
    #     nil               — model has no thinking concept (don't send thinking)
    #     :budget_tokens    — RubyLLM's default Anthropic shape (Opus 4.6, Sonnet 4.x)
    #     :reasoning_effort — OpenAI-style reasoning_effort string
    #     :adaptive         — Opus 4.7+ adaptive shape (output_config.effort)
    #   accepts_temperature        — false → normalizer strips @temperature
    #   tools_with_thinking_native — true → tools + thinking on default endpoint OK
    #   tools_with_thinking_route  — nil | :responses (which endpoint to route to
    #                                when both tools + thinking are present and
    #                                native combo is unsupported)
    Profile = Data.define(
      :model_id,
      :provider,
      :thinking_shape,
      :accepts_temperature,
      :tools_with_thinking_native,
      :tools_with_thinking_route
    ) do
      # Derived from tools_with_thinking_route. Exposed on Profile (not on
      # Tool::Compatibility) so the Profile is a self-contained capability
      # record without cross-namespace dependency.
      def endpoint_mode
        tools_with_thinking_route == :responses ? :responses : :chat_completions
      end
    end
  end
end
