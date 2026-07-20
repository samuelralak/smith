# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module ExecutionLifecycle
        private

        def perform_authorized_prepared_step_execution!(authorization)
          authorization = validate_split_step_execution_authorization!(authorization)
          execution_thread = Thread.current
          execute_prepared_step_lifecycle!(authorization, execution_thread) { yield(execution_thread) }
        end

        def execute_prepared_step_lifecycle!(authorization, execution_thread)
          execution_active = false
          step = nil
          result = nil
          Thread.handle_interrupt(Object => :never) do
            activate_split_step_execution!(authorization, execution_thread)
            execution_active = true
            Thread.handle_interrupt(Object => :immediate) do
              step, result = yield(execution_thread)
            end
          ensure
            finish_split_step_execution!(step, authorization, execution_thread) if execution_active
          end
          result
        end

        def activate_split_step_execution!(authorization, execution_thread)
          Thread.handle_interrupt(Object => :never) do
            @split_step_mutex.synchronize do
              ensure_active_split_step_execution_authorization!(authorization)
              ensure_split_step_definition_current!
              ensure_prepared_split_step_transition_matches!
              activate_prepared_step_execution_scope!(authorization)
              publish_active_split_step_execution!(authorization, execution_thread)
            end
          end
        end

        def finish_split_step_execution!(step, authorization, execution_thread)
          Thread.handle_interrupt(Object => :never) do
            @split_step_mutex.synchronize do
              reset_active_split_step_execution!(step) if active_split_step_execution?(execution_thread)
            end
          ensure
            PreparedStepExecutionAuthorization.instance_method(:close_execution!).bind_call(authorization)
          end
        end

        def ensure_active_split_step_execution_authorization!(authorization)
          return if active_split_step_execution_authorization?(authorization)

          raise WorkflowError, "the prepared-step execution authorization is no longer active"
        end

        def activate_prepared_step_execution_scope!(authorization)
          PreparedStepExecutionAuthorization.instance_method(:activate_execution!).bind_call(authorization)
        end

        def publish_active_split_step_execution!(authorization, execution_thread)
          @split_step_active_execution_authorization = authorization
          @split_step_execution_result = nil
          @split_step_phase = :executing
          clear_split_step_execution_authorization!
          @split_step_execution_thread = execution_thread
          @split_step_advance_permit = true
        end

        def active_split_step_execution?(execution_thread)
          @split_step_phase == :executing && @split_step_execution_thread.equal?(execution_thread)
        end

        def reset_active_split_step_execution!(step)
          @split_step_execution_thread = nil
          @split_step_advance_permit = false
          @split_step_execution_previous_phase = nil
          @split_step_active_execution_authorization = nil
          @split_step_execution_result = nil
          @split_step_phase = step ? :executed : :attempted
        end

        def release_failed_execution_authorization!(authorization)
          return unless authorization
          return unless active_split_step_execution_authorization?(authorization)

          ExecutionAuthorization
            .instance_method(:release_prepared_step_execution!)
            .bind_call(self, authorization)
        end
      end
    end
  end
end
