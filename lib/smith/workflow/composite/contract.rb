# frozen_string_literal: true

require_relative "branch_contract"
require_relative "branch_execution"
require_relative "execution_contract"
require_relative "input"
require_relative "plan"
require_relative "../composite_branch_execution_authorization"

module Smith
  class Workflow
    module Composite
      module Contract
        include BranchContract
        include ExecutionContract

        private

        def validate_composite_authorization!(authorization)
          authorization = validate_split_step_execution_authorization!(authorization)
          @split_step_mutex.synchronize do
            unless active_split_step_execution_authorization?(authorization)
              raise WorkflowError, "the prepared-step execution authorization is no longer active"
            end

            ensure_split_step_definition_current!
            ensure_prepared_split_step_transition_matches!
          end
          validate_composite_transition!(@split_step_transition)
          unless authorization.dispatch_claim
            raise WorkflowError, "durable composite execution requires a prepared-step dispatch"
          end

          authorization
        end

        def validate_composite_transition!(transition)
          unless transition&.fanout? || transition&.parallel?
            raise WorkflowError, "prepared transition is not a supported composite"
          end
          raise WorkflowError, "durable composite retries are not supported" if transition.retry_config

          transition
        end

        def validate_composite_plan!(authorization, plan, input)
          validate_composite_payload_types!(plan, input)
          validate_composite_dispatch!(authorization, plan)
          validate_composite_input!(plan, input)
          validate_composite_budget_state!(plan)
          validate_composite_execution_namespace!(plan)
          transition = @split_step_transition
          validate_composite_transition_identity!(plan, transition)
          plan
        end

        def validate_composite_branch_execution!(authorization, execution, input)
          validate_composite_branch_payload_types!(execution, input)
          validate_composite_dispatch_value!(authorization, execution.dispatch)
          validate_composite_input_digest!(execution.input_digest, input)
          validate_composite_budget_state_digest!(execution.budget_state_digest)
          validate_composite_execution_namespace_value!(execution.execution_namespace)
          validate_composite_transition_values!(execution, @split_step_transition)
          validate_composite_branch_count!(execution.branch_count)
          validate_composite_branch_authorization!(authorization, execution, input)
          validate_composite_selected_branch!(authorization, execution, @split_step_transition)
          execution
        end

        def validate_composite_reduction_plan!(authorization, plan, input)
          validate_composite_plan!(authorization, plan, input)
          validate_composite_branches!(authorization, plan, @split_step_transition)
          plan
        end

        def validate_composite_payload_types!(plan, input)
          raise ArgumentError, "plan must be a Smith composite plan" unless plan.is_a?(Plan)
          raise ArgumentError, "input must be a Smith composite input" unless input.is_a?(Input)
        end

        def validate_composite_branch_payload_types!(execution, input)
          unless execution.is_a?(BranchExecution)
            raise ArgumentError, "execution must be a Smith composite branch execution"
          end
          raise ArgumentError, "input must be a Smith composite input" unless input.is_a?(Input)
        end

        def validate_composite_branch_authorization!(authorization, execution, input)
          unless authorization.instance_of?(CompositeBranchExecutionAuthorization)
            raise ArgumentError, "authorization must be a Smith composite branch authorization"
          end

          CompositeBranchExecutionAuthorization
            .instance_method(:verify_composite_branch!)
            .bind_call(authorization, execution, input)
        end
      end
    end
  end
end
