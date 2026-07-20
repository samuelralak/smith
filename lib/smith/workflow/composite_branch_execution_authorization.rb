# frozen_string_literal: true

require_relative "prepared_step_execution_authorization"
require_relative "composite/branch_execution"
require_relative "composite/input"

module Smith
  class Workflow
    class CompositeBranchExecutionAuthorization < PreparedStepExecutionAuthorization
      attr_reader :execution_digest, :plan_digest, :input_digest, :branch_digest,
                  :branch_ordinal, :execution_namespace

      def initialize(execution:, input:, **attributes)
        validate_payloads!(execution, input)
        @execution_digest = execution.digest.dup.freeze
        @plan_digest = execution.plan_digest.dup.freeze
        @input_digest = input.digest.dup.freeze
        assign_branch_identity(execution.branch)
        @execution_namespace = execution.execution_namespace.dup.freeze
        super(**attributes)
      end

      private

      def validate_payloads!(execution, input)
        return if execution.is_a?(Composite::BranchExecution) && input.is_a?(Composite::Input)

        raise ArgumentError, "composite branch authorization requires typed execution and input"
      end

      def assign_branch_identity(branch)
        @branch_digest = branch.digest.dup.freeze
        @branch_ordinal = branch.ordinal
      end

      def verify_composite_branch!(execution, input)
        validate_payloads!(execution, input)
        expected = [
          execution_digest, plan_digest, branch_digest, branch_ordinal,
          execution_namespace, input_digest
        ]
        actual = [
          execution.digest, execution.plan_digest, execution.branch.digest,
          execution.branch.ordinal, execution.execution_namespace, input.digest
        ]
        return if actual == expected

        raise WorkflowError, "composite branch authorization does not match execution"
      end
    end
  end
end
