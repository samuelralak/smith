# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module Execution
        def execute_prepared_step!
          execution_started = false
          step = nil
          claim_split_step_execution_verification!
          begin
            verify_claimed_split_step_execution!
            activate_split_step_execution!
            execution_started = true
            step = execute_claimed_split_step_transition!
          ensure
            execution_started ? finish_split_step_execution!(step) : restore_unverified_execution!
          end
          step
        end

        def prepared_persisted_step?
          @split_step_mutex.synchronize do
            expected = restart_safe_split_step? ? :dispatch_claimed : :prepared
            @split_step_phase == expected
          end
        end

        private

        def activate_split_step_execution!
          @split_step_mutex.synchronize do
            unless @split_step_phase == :verifying_execution
              raise WorkflowError, "the prepared execution claim is no longer active"
            end

            @split_step_phase = :executing
            @split_step_execution_previous_phase = nil
            @split_step_execution_thread = Thread.current
            @split_step_advance_permit = true
          end
        end

        def restore_unverified_execution!
          @split_step_mutex.synchronize do
            if @split_step_phase == :verifying_execution
              @split_step_phase = @split_step_execution_previous_phase
              @split_step_execution_previous_phase = nil
            end
          end
        end

        def execute_claimed_split_step_transition!
          step = Workflow.instance_method(:advance!).bind_call(self)
          return step if accepted_split_step_result?(step)

          raise WorkflowError, "prepared execution did not return the claimed transition"
        end

        def finish_split_step_execution!(step)
          @split_step_mutex.synchronize do
            @split_step_execution_thread = nil
            @split_step_advance_permit = false
            @split_step_execution_previous_phase = nil
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
