# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module ExecutionAuthorization
        def release_prepared_step_execution!(authorization)
          authorization = validate_split_step_execution_authorization!(authorization)
          Thread.handle_interrupt(Object => :never) do
            @split_step_mutex.synchronize do
              unless active_split_step_execution_authorization?(authorization)
                raise WorkflowError, "the prepared-step execution authorization is no longer active"
              end

              @split_step_phase = @split_step_execution_previous_phase
              clear_split_step_execution_authorization!
            end
            PreparedStepExecutionAuthorization
              .instance_method(:close_execution!)
              .bind_call(authorization)
          end
          self
        end

        private

        def authorize_claimed_prepared_step_execution!(verification_token)
          ExecutionVerification
            .instance_method(:verify_claimed_split_step_execution!)
            .bind_call(self, verification_token)
          authorization = ExecutionAuthorization
                          .instance_method(:build_split_step_execution_authorization)
                          .bind_call(self)
          ExecutionAuthorization
            .instance_method(:activate_split_step_execution_authorization!)
            .bind_call(self, authorization, verification_token)
          authorization
        end

        def claim_framework_execution_verification!
          ExecutionVerification
            .instance_method(:claim_split_step_execution_verification!)
            .bind_call(self)
        end

        def restore_framework_execution_verification!(verification_token)
          return unless verification_token

          active = ExecutionAuthorization
                   .instance_method(:active_split_step_execution_verification?)
                   .bind_call(self, verification_token)
          return unless active

          Execution.instance_method(:restore_unverified_execution!).bind_call(self, verification_token)
        end

        def build_split_step_execution_authorization
          PreparedStepExecutionAuthorization.new(
            prepared_step: @split_step_prepared_descriptor,
            dispatch_claim: @split_step_dispatch_descriptor,
            execution_bindings: ExecutionBindingSnapshot.capture(
              @split_step_transition,
              workflow_class: self.class
            )
          )
        end

        def activate_split_step_execution_authorization!(authorization, verification_token)
          @split_step_mutex.synchronize do
            unless active_split_step_execution_verification?(verification_token)
              raise WorkflowError, "the prepared execution verification is no longer active"
            end

            @split_step_execution_authorization = authorization
            clear_split_step_execution_verification!
            @split_step_phase = :execution_authorized
          end
        end

        def validate_split_step_execution_authorization!(authorization)
          return authorization if authorization.is_a?(PreparedStepExecutionAuthorization)

          raise ArgumentError,
                "authorization must be a Smith::Workflow::PreparedStepExecutionAuthorization"
        end

        def active_split_step_execution_authorization?(authorization)
          @split_step_phase == :execution_authorized &&
            @split_step_execution_authorization.equal?(authorization) &&
            authorization.issued_in_current_process?
        end

        def active_split_step_execution_verification?(verification_token)
          @split_step_phase == :verifying_execution &&
            @split_step_execution_verification_token.equal?(verification_token)
        end

        def clear_split_step_execution_verification!
          @split_step_execution_verification_token = nil
        end

        def clear_split_step_execution_authorization!
          @split_step_execution_authorization = nil
          @split_step_execution_previous_phase = nil
        end
      end
    end
  end
end
