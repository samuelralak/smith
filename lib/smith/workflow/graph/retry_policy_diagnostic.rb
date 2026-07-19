# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      class RetryPolicyDiagnostic
        extend Dry::Initializer

        option :transition

        def call
          attempts = transition.retry_config&.fetch(:attempts, nil)
          limit = Smith.config.retry_attempt_limit
          return unless attempts && attempts > limit

          Diagnostic.new(
            severity: :error,
            code: :retry_attempt_limit_exceeded,
            transition: transition.name,
            message: "Transition #{ref(transition.name)} declares #{attempts} retry attempts, " \
                     "exceeding the configured limit #{limit}.",
            suggestion: "Reduce the retry attempts or explicitly raise Smith.config.retry_attempt_limit."
          )
        end

        private

        def ref(value)
          Reference.format(value)
        end
      end
    end
  end
end
