# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # In an isolated session an agent step has no transcript to read, so it
      # must declare `input:`; without one it fails at runtime.
      class IsolatedInputDiagnostic
        extend Dry::Initializer

        option :transition
        option :workflow_class

        def call
          return unless workflow_class.respond_to?(:session) && workflow_class.session == :isolated
          return if transition.step_input || !agent_step?

          name = Reference.format(transition.name)
          Diagnostic.new(
            severity: :error, code: :isolated_step_without_input, transition: transition.name,
            message: "Transition #{name} runs an agent in an isolated session without input:.",
            suggestion: "Declare input: on transition #{name}, or use session :shared."
          )
        end

        private

        def agent_step?
          !transition.agent_name.nil? || transition.optimized? || transition.orchestrated? || transition.fanout?
        end
      end
    end
  end
end
