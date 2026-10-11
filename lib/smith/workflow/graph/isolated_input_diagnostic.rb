# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # In an isolated session an agent step has no transcript to read, so it
      # must declare `input:`; without one it fails at runtime. A nested
      # workflow keeps its own session mode, so an isolated workflow that
      # nests a shared one is reported too.
      class IsolatedInputDiagnostic
        extend Dry::Initializer

        option :transition
        option :workflow_class

        def call
          return unless isolated?(workflow_class)
          return nested_shared_session if transition.nested?
          return if transition.step_input || !transition.agent_step?

          name = Reference.format(transition.name)
          Diagnostic.new(
            severity: :error, code: :isolated_step_without_input, transition: transition.name,
            message: "Transition #{name} runs an agent in an isolated session without input:.",
            suggestion: "Declare input: on transition #{name}, or use session :shared."
          )
        end

        private

        def isolated?(klass) = klass.respond_to?(:session) && klass.session == :isolated

        def nested_shared_session
          child = transition.workflow_class
          return if isolated?(child)

          label = child.name || child.inspect
          Diagnostic.new(
            severity: :warning, code: :isolated_workflow_nests_shared_session, transition: transition.name,
            target: label,
            message: "Transition #{Reference.format(transition.name)} nests #{label}, whose agents share a transcript.",
            suggestion: "Declare session :isolated on #{label} if its agents should not read one another's output."
          )
        end
      end
    end
  end
end
