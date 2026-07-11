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
            verify_split_step_preparation_available!
            activate_split_step_execution!
            execution_started = true
            step = execute_claimed_split_step_transition!
          ensure
            execution_started ? finish_split_step_execution!(step) : restore_unverified_execution!
          end
          step
        end

        def prepared_persisted_step? = @split_step_mutex.synchronize { @split_step_phase == :prepared }

        private

        def claim_split_step_execution_verification!
          @split_step_mutex.synchronize do
            raise WorkflowError, "no persisted step is prepared" unless @split_step_phase == :prepared
            raise WorkflowError, "the prepared transition no longer matches the workflow" unless
              prepared_split_step_transition_matches?

            @split_step_phase = :verifying_execution
          end
        end

        def prepared_split_step_transition_matches?
          transition = pending_split_step_transition
          transition_name = @next_transition_name || transition&.name
          transition_name == @split_step_transition_name &&
            transition.equal?(@split_step_transition) &&
            split_step_transition_signature(transition) == @split_step_transition_signature
        end

        def activate_split_step_execution!
          @split_step_mutex.synchronize do
            unless @split_step_phase == :verifying_execution
              raise WorkflowError, "the prepared execution claim is no longer active"
            end

            @split_step_phase = :executing
            @split_step_execution_thread = Thread.current
            @split_step_advance_permit = true
          end
        end

        def restore_unverified_execution!
          @split_step_mutex.synchronize do
            @split_step_phase = :prepared if @split_step_phase == :verifying_execution
          end
        end

        def verify_split_step_preparation_available!
          payload = @split_step_adapter.fetch(@split_step_persistence_key)
          durable = persisted_split_step_payload?(payload, @split_step_preparation_payload)
          live = persisted_split_step_payload?(current_split_step_preparation_payload, @split_step_preparation_payload)
          stable = split_step_transition_signature(@split_step_transition) == @split_step_transition_signature
          return if durable && live && stable

          raise WorkflowError, "the persisted split-step preparation is no longer available"
        end

        def current_split_step_preparation_payload
          split_step_preparation_payload(
            JSON.generate(to_state.merge(persistence_version: @persistence_version))
          )
        end

        def execute_claimed_split_step_transition!
          step = advance!
          return step if accepted_split_step_result?(step)

          raise WorkflowError, "prepared execution did not return the claimed transition"
        end

        def finish_split_step_execution!(step)
          @split_step_mutex.synchronize do
            @split_step_execution_thread = nil
            @split_step_advance_permit = false
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
