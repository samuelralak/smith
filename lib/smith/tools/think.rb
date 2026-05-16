# frozen_string_literal: true

module Smith
  module Tools
    class Think < Smith::Tool
      description "Think through your approach between steps. " \
                  "Plan what to do next, evaluate progress, and identify gaps."
      category :computation

      # Compatible with Anthropic (extended thinking is native), Gemini
      # (thinking is the default request shape), and OpenAI BUT ONLY on
      # /v1/responses — chat-completions rejects function tools combined
      # with reasoning_effort for the gpt-5 family. The normalizer uses
      # this spec when deciding whether to drop Think on a model whose
      # profile rejects (tools + thinking) AND no routing fallback exists.
      compatible_with :anthropic, :gemini, openai: :responses

      param :thought, type: :string, required: true

      def perform(thought:) # rubocop:disable Lint/UnusedMethodArgument
        { acknowledged: true }
      end
    end
  end
end
