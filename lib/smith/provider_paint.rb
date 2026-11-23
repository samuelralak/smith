# frozen_string_literal: true

require_relative "paint_input"
require_relative "painted_answer"

module Smith
  # An image agent's attempt (ImageRequest) paints instead of completing.
  # Smith::ImageAttempt makes it, so a workflow including this module gains
  # no name beyond 0.15.0's `attempt_model`.
  module ProviderPaint
    # A moderation block, which OpenAI's Images API answers as a bad
    # request, is a refused response.
    def self.refused?(error) = error.is_a?(::RubyLLM::BadRequestError) && PaintedAnswer.moderation_blocked?(error)

    private

    # Every attempt an image agent makes (a candidate, a refusal's fallback,
    # a retry) paints; any other agent's completes (ProviderCompletion).
    # Only the agent's `image` declaration makes it an image agent.
    def attempt_model(agent_class, prepared_input, model_reference, shape:, attempt_index:)
      return super unless ImageRequest.declared(agent_class)

      ImageAttempt.new(self, agent_class).call(prepared_input, model_reference, attempt_index:)
    end
  end
end
