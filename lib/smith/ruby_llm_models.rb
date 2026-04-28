# frozen_string_literal: true

require "ruby_llm"

module Smith
  module RubyLLMModels
    CLAUDE_OPUS_4_7 = {
      id: "claude-opus-4-7",
      name: "Claude Opus 4.7",
      provider: "anthropic",
      family: "claude-opus",
      created_at: "2026-04-16 00:00:00 UTC",
      context_window: 1_000_000,
      max_output_tokens: 128_000,
      modalities: {
        input: %w[text image pdf],
        output: %w[text]
      },
      capabilities: %w[function_calling structured_output reasoning vision streaming],
      pricing: {
        text_tokens: {
          standard: {
            input_per_million: 5.0,
            output_per_million: 25.0,
            cached_input_per_million: 0.5
          }
        }
      },
      metadata: {
        source: "smith",
        provider_id: "anthropic",
        last_updated: "2026-04-16",
        status: "available"
      }
    }.freeze

    def self.install!
      install_model(CLAUDE_OPUS_4_7)
    end

    def self.install_model(data)
      registry = ::RubyLLM.models
      models = registry.all
      return if models.any? { |model| model.id == data[:id] && model.provider == data[:provider] }

      model = ::RubyLLM::Model::Info.new(data)
      registry.instance_variable_set(:@models, (models + [model]).sort_by { |entry| [entry.provider, entry.id] })
    end
    private_class_method :install_model
  end

  module RubyLLMAnthropicOpus47Compat
    OPUS_4_7_MODEL_ID = "claude-opus-4-7"
    DEFAULT_ADAPTIVE_EFFORT = "high"

    # RubyLLM 1.14.x predates Opus 4.7's adaptive-only thinking payload.
    # Patch after the base payload is rendered so schema output_config survives.
    # rubocop:disable Metrics/ParameterLists
    def render_payload(messages, tools:, temperature:, model:, stream: false,
                       schema: nil, thinking: nil, tool_prefs: nil)
      ruby_llm_thinking = ruby_llm_render_thinking(model, thinking)

      super(
        messages,
        tools: tools,
        temperature: temperature,
        model: model,
        stream: stream,
        schema: schema,
        thinking: ruby_llm_thinking,
        tool_prefs: tool_prefs
      ).tap do |payload|
        next unless model.id == OPUS_4_7_MODEL_ID

        payload.delete(:temperature)

        if thinking&.enabled?
          payload[:thinking] = { type: "adaptive" }
          payload[:output_config] ||= {}
          payload[:output_config][:effort] = adaptive_effort(thinking)
        end
      end
    end
    # rubocop:enable Metrics/ParameterLists

    private

    def adaptive_effort(thinking)
      return thinking.effort if thinking.respond_to?(:effort) && thinking.effort

      DEFAULT_ADAPTIVE_EFFORT
    end

    def ruby_llm_render_thinking(model, thinking)
      return thinking unless model.id == OPUS_4_7_MODEL_ID && thinking&.enabled?
      return thinking if thinking.respond_to?(:budget) && thinking.budget.is_a?(Integer)

      RubyLLM::Thinking::Config.new(budget: 1)
    end
  end
end

Smith::RubyLLMModels.install!

# Prepend on the provider CLASS, not on Chat's singleton class:
# `class Anthropic < Provider; include Anthropic::Chat; end` mixes
# Chat's methods in as INSTANCE methods. Calls go through
# `provider_instance.render_payload(...)`, which dispatches via the
# Anthropic class's instance-method lookup chain. Prepending on
# `Chat.singleton_class` only intercepts `Chat.render_payload(...)`
# module-method calls (the `module_function` path), which the runtime
# never takes. Prepending on `Anthropic` itself sits in front of the
# Chat-derived instance method and actually fires for every request.
unless RubyLLM::Providers::Anthropic.ancestors.include?(Smith::RubyLLMAnthropicOpus47Compat)
  RubyLLM::Providers::Anthropic.prepend(Smith::RubyLLMAnthropicOpus47Compat)
end
