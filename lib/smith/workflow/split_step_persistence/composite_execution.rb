# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module CompositeExecution
        def prepare_composite_step!
          ExecutionAuthorizationIssuance
            .instance_method(:with_prepared_step_execution_authorization)
            .bind_call(self) do |authorization|
              CompositePreparation
                .instance_method(:prepare_authorized_composite_step!)
                .bind_call(self, authorization)
            end
        end

        def execute_prepared_composite_branch!(execution:, input:)
          CompositeBranchAuthorization
            .instance_method(:with_composite_branch_authorization)
            .bind_call(self, execution, input) do |authorization|
              CompositeBranchExecution
                .instance_method(:execute_authorized_composite_branch!)
                .bind_call(self, authorization, execution:, input:)
            end
        end

        def reduce_prepared_composite_step!(plan:, input:, outcomes:, primary_failure: nil)
          ExecutionAuthorizationIssuance
            .instance_method(:with_prepared_step_execution_authorization)
            .bind_call(self) do |authorization|
              CompositeReductionExecution
                .instance_method(:reduce_authorized_composite_step!)
                .bind_call(self, authorization, plan:, input:, outcomes:, primary_failure:)
            end
        end
      end
    end
  end
end
