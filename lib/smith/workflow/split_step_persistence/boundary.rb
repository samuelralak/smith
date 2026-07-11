# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module Boundary
        def run_persisted!(...)
          ensure_no_split_step_boundary!
          super
        end

        def advance_persisted!(...)
          ensure_no_split_step_boundary!
          super
        end

        def clear_persisted!(...)
          ensure_no_split_step_boundary!
          super
        end

        def initialize_copy(source)
          super
          @split_step_mutex = Mutex.new
          return unless source.instance_variable_get(:@split_step_phase)

          @split_step_phase = :copied_boundary
          @split_step_token = nil
          @split_step_execution_thread = nil
          @split_step_advance_permit = false
          @split_step_preparation_thread = nil
          @split_step_persist_permit = false
        end
        private :initialize_copy

        private

        def ensure_split_step_execution_allowed!
          @split_step_mutex.synchronize do
            return unless @split_step_phase

            if split_step_advance_permitted?
              @split_step_advance_permit = false
              return
            end
          end

          raise WorkflowError, "use execute_prepared_step! for the active split-step boundary"
        end

        def claim_split_step_advance!
          @split_step_mutex.synchronize do
            unless @split_step_phase
              @split_step_phase = :ordinary_execution
              return :ordinary
            end
            if split_step_advance_permitted?
              @split_step_advance_permit = false
              return :split_step
            end

            raise WorkflowError, "use execute_prepared_step! for the active split-step boundary"
          end
        end

        def release_split_step_advance!(claim)
          return unless claim == :ordinary

          @split_step_mutex.synchronize do
            @split_step_phase = nil if @split_step_phase == :ordinary_execution
          end
        end

        def ensure_no_split_step_boundary!
          return unless @split_step_phase

          raise WorkflowError, "a split-step persistence boundary is already active"
        end

        def split_step_advance_permitted?
          @split_step_phase == :executing &&
            @split_step_execution_thread.equal?(Thread.current) &&
            @split_step_advance_permit
        end

        def clear_split_step_boundary!
          @split_step_phase = nil
          @split_step_transition_name = nil
          @split_step_transition = nil
          @split_step_transition_signature = nil
          @split_step_origin_state = nil
          @split_step_token = nil
          @split_step_persistence_key = nil
          @split_step_adapter = nil
          remove_instance_variable(:@split_step_persistence_ttl) if
            instance_variable_defined?(:@split_step_persistence_ttl)
          @split_step_preparation_payload = nil
          @split_step_checkpoint_digests = nil
          @split_step_checkpoint_version = nil
          @split_step_preparation_thread = nil
          @split_step_persist_permit = false
        end
      end
    end
  end
end
