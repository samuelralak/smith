# frozen_string_literal: true

class SpecBoundedRubyLLMChat < RubyLLM::Chat
  attr_reader :provider_snapshots

  def initialize(responses:, context:)
    @responses = responses.dup
    @provider_snapshots = []
    super(model: "bounded-test", provider: :openai, assume_model_exists: true, context: context)
  end

  private

  def provider_completion
    @provider_snapshots << {
      tools: tools.keys,
      tool_prefs: tool_prefs.dup,
      concurrency: concurrency
    }
    response = @responses.shift || raise("unexpected provider completion")
    response = response.call if response.respond_to?(:call)
    raise response if response.is_a?(Exception)

    response
  end
end
