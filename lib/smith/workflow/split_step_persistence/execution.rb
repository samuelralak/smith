# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module Execution
        def execute_prepared_step!
          authorization = ExecutionAuthorization
                          .instance_method(:authorize_prepared_step_execution!)
                          .bind_call(self)
          result = Execution.instance_method(:execute_authorized_prepared_step!).bind_call(self, authorization)
          result.step_snapshot
        end

        def execute_authorized_prepared_step!(authorization)
          authorization = validate_split_step_execution_authorization!(authorization)
          step = nil
          result = nil
          execution_thread = Thread.current
          begin
            activate_split_step_execution!(authorization, execution_thread)
            step = execute_claimed_split_step_transition!
            result = consume_split_step_execution_result!(execution_thread)
          ensure
            finish_split_step_execution!(step, execution_thread)
          end
          result
        end

        def prepared_persisted_step?
          @split_step_mutex.synchronize do
            expected = restart_safe_split_step? ? :dispatch_claimed : :prepared
            [expected, :execution_authorized].include?(@split_step_phase)
          end
        end

        private

        def activate_split_step_execution!(authorization, execution_thread)
          @split_step_mutex.synchronize do
            unless active_split_step_execution_authorization?(authorization)
              raise WorkflowError, "the prepared-step execution authorization is no longer active"
            end

            ensure_split_step_definition_current!
            ensure_prepared_split_step_transition_matches!

            @split_step_active_execution_authorization = authorization
            @split_step_execution_result = nil
            @split_step_phase = :executing
            clear_split_step_execution_authorization!
            @split_step_execution_thread = execution_thread
            @split_step_advance_permit = true
          end
        end

        def restore_unverified_execution!(verification_token)
          @split_step_mutex.synchronize do
            next unless active_split_step_execution_verification?(verification_token)

            @split_step_phase = @split_step_execution_previous_phase
            @split_step_execution_previous_phase = nil
            clear_split_step_execution_verification!
          end
        end

        def execute_claimed_split_step_transition!
          step = Workflow.instance_method(:advance!).bind_call(self)
          return step if accepted_split_step_result?(step)

          raise WorkflowError, "prepared execution did not return the claimed transition"
        end

        def finish_split_step_execution!(step, execution_thread)
          @split_step_mutex.synchronize do
            return unless @split_step_phase == :executing &&
                          @split_step_execution_thread.equal?(execution_thread)

            @split_step_execution_thread = nil
            @split_step_advance_permit = false
            @split_step_execution_previous_phase = nil
            @split_step_active_execution_authorization = nil
            @split_step_execution_result = nil
            @split_step_phase = step ? :executed : :attempted
          end
        end

        def resolve_split_step_advance_transition
          @split_step_mutex.synchronize do
            unless @split_step_phase == :executing && @split_step_execution_thread.equal?(Thread.current)
              return NO_SPLIT_TRANSITION
            end

            name = @next_transition_name
            @next_transition_name = nil if name
            raise UnresolvedTransitionError.new(name, self.class, @state) if name && @split_step_transition.nil?

            @split_step_transition
          end
        end

        def accepted_split_step_result?(step)
          return false unless step.is_a?(Hash)
          return false unless step[:transition] == @split_step_transition_name
          return false unless step[:from] == @split_step_origin_state

          step[:error] ? accepted_split_step_failure? : step.key?(:to) && @state == step[:to]
        end

        def accepted_split_step_failure?
          failure_name = @split_step_transition&.failure_transition || :fail
          failure_transition = self.class.find_transition(failure_name)
          return false unless failure_transition

          @state == failure_transition.to ||
            (@state == @split_step_origin_state && @next_transition_name == failure_name)
        end
      end
    end
  end
end
