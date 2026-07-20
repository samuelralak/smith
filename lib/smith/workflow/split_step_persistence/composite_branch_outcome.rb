# frozen_string_literal: true

require_relative "../composite/branch_outcome"
require_relative "../composite/error_evidence"

module Smith
  class Workflow
    module SplitStepPersistence
      module CompositeBranchOutcome
        private

        def composite_branch_outcome(execution, output, error, effects)
          return failed_composite_branch_outcome(execution, error, effects) if error

          Composite::BranchOutcome.succeeded(
            plan_digest: execution.plan_digest,
            branch: execution.branch,
            output: output.fetch(:output),
            effects:
          )
        rescue WorkflowError, ArgumentError => e
          failed_composite_branch_outcome(execution, e, effects)
        end

        def failed_composite_branch_outcome(execution, error, effects)
          Composite::BranchOutcome.failed(
            plan_digest: execution.plan_digest,
            branch: execution.branch,
            error: Composite::ErrorEvidence.call(error),
            effects:
          )
        end
      end
    end
  end
end
