# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # Past its deadline an await takes `on_timeout`, else `on_failure`;
      # with neither, expiry raises and leaves the run waiting.
      class AwaitTimeoutRouteDiagnostic
        extend Dry::Initializer

        option :transition
        option :workflow_class, optional: true

        def call
          return unless transition.awaits? && !transition.delay?
          return if transition.timeout_transition || transition.failure_transition

          name = Reference.format(transition.name)
          Diagnostic.new(
            severity: :error, code: :await_without_timeout_route, transition: transition.name,
            message: "Await transition #{name} has no route for its timeout.",
            suggestion: "Declare on_timeout or on_failure on transition #{name}."
          )
        end
      end
    end
  end
end
