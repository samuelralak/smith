# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module ExecutionAuthorizationIssuance
        def authorize_prepared_step_execution!
          authorization = nil
          handed_off = false
          authorization = ExecutionAuthorizationIssuance
                          .instance_method(:interrupt_safe_prepared_step_authorization)
                          .bind_call(self)
          handed_off = true
          authorization
        ensure
          unless handed_off
            ExecutionLifecycle
              .instance_method(:release_failed_execution_authorization!)
              .bind_call(self, authorization)
          end
        end

        private

        def with_prepared_step_execution_authorization
          Thread.handle_interrupt(Object => :never) do
            authorization = interrupt_safe_prepared_step_authorization
            begin
              Thread.handle_interrupt(Object => :immediate) { yield(authorization) }
            ensure
              ExecutionLifecycle
                .instance_method(:release_failed_execution_authorization!)
                .bind_call(self, authorization)
            end
          end
        end

        def interrupt_safe_prepared_step_authorization
          Thread.handle_interrupt(Object => :never) do
            verification_token = ExecutionAuthorization
                                 .instance_method(:claim_framework_execution_verification!)
                                 .bind_call(self)
            begin
              ExecutionAuthorization
                .instance_method(:authorize_claimed_prepared_step_execution!)
                .bind_call(self, verification_token)
            ensure
              ExecutionAuthorization
                .instance_method(:restore_framework_execution_verification!)
                .bind_call(self, verification_token)
            end
          end
        end
      end
    end
  end
end
