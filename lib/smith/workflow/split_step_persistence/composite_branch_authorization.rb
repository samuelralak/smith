# frozen_string_literal: true

require_relative "../composite/contract"
require_relative "../composite_branch_execution_authorization"
require_relative "execution_binding_snapshot"

module Smith
  class Workflow
    module SplitStepPersistence
      module CompositeBranchAuthorization
        include Composite::Contract

        private

        def authorize_prepared_composite_branch_execution!(execution:, input:)
          authorization = nil
          handed_off = false
          authorization = CompositeBranchAuthorization
                          .instance_method(:interrupt_safe_composite_branch_authorization)
                          .bind_call(self, execution, input)
          handed_off = true
          authorization
        ensure
          unless handed_off
            ExecutionLifecycle
              .instance_method(:release_failed_execution_authorization!)
              .bind_call(self, authorization)
          end
        end

        def with_composite_branch_authorization(execution, input)
          Thread.handle_interrupt(Object => :never) do
            authorization = interrupt_safe_composite_branch_authorization(execution, input)
            begin
              Thread.handle_interrupt(Object => :immediate) { yield(authorization) }
            ensure
              ExecutionLifecycle
                .instance_method(:release_failed_execution_authorization!)
                .bind_call(self, authorization)
            end
          end
        end

        def interrupt_safe_composite_branch_authorization(execution, input)
          Thread.handle_interrupt(Object => :never) do
            Composite::Contract
              .instance_method(:validate_composite_branch_payload_types!)
              .bind_call(self, execution, input)
            verification_token = ExecutionAuthorization
                                 .instance_method(:claim_framework_execution_verification!)
                                 .bind_call(self)
            begin
              CompositeBranchAuthorization
                .instance_method(:authorize_claimed_composite_branch_execution!)
                .bind_call(self, verification_token, execution, input)
            ensure
              ExecutionAuthorization
                .instance_method(:restore_framework_execution_verification!)
                .bind_call(self, verification_token)
            end
          end
        end

        def authorize_claimed_composite_branch_execution!(verification_token, execution, input)
          ExecutionVerification
            .instance_method(:verify_claimed_split_step_execution!)
            .bind_call(self, verification_token)
          authorization = CompositeBranchAuthorization
                          .instance_method(:build_composite_branch_execution_authorization)
                          .bind_call(self, execution, input)
          ExecutionAuthorization
            .instance_method(:activate_split_step_execution_authorization!)
            .bind_call(self, authorization, verification_token)
          Composite::Contract
            .instance_method(:validate_composite_branch_execution!)
            .bind_call(self, authorization, execution, input)
          authorization
        end

        def build_composite_branch_execution_authorization(execution, input)
          role = execution.kind == :parallel ? :agent : :fanout_agent
          bindings = ExecutionBindingSnapshot.capture_agent(
            @split_step_transition,
            workflow_class: self.class,
            name: execution.branch.agent,
            role:
          )
          CompositeBranchExecutionAuthorization.new(
            execution:,
            input:,
            prepared_step: @split_step_prepared_descriptor,
            dispatch_claim: @split_step_dispatch_descriptor,
            execution_bindings: bindings
          )
        end
      end
    end
  end
end
