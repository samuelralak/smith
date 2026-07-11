# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module StateSnapshot
        def to_state
          state = super
          return state unless split_step_boundary_active?

          snapshot_value(state)
        end

        def session_messages
          return super unless split_step_boundary_active?

          snapshot_session_messages
        end

        def ledger
          return super unless split_step_boundary_active?
          return unless @ledger

          snapshot_split_step_ledger
        end

        private

        def effective_persistence_ttl
          return super unless split_step_boundary_active?
          return super unless instance_variable_defined?(:@split_step_persistence_ttl)

          @split_step_persistence_ttl
        end

        def ttl_kwarg(ttl)
          return super unless split_step_boundary_active?
          return super unless instance_variable_defined?(:@split_step_persistence_ttl)

          { ttl: ttl }
        end

        def detach_split_step_execution_state!
          detach_split_step_collections!
          detach_split_step_results!
          detach_split_step_metadata!
          @ledger = snapshot_split_step_ledger if @ledger
        end

        def detach_split_step_collections!
          @context = snapshot_context
          @session_messages = snapshot_session_messages
          @tool_results = snapshot_tool_results
          @outcome = snapshot_outcome
          @usage_entries = snapshot_usage_entries
          @persisted_keys = Set.new(snapshot_value((@persisted_keys || Set.new).to_a))
        end

        def detach_split_step_results!
          @last_output = snapshot_value(@last_output)
          @last_failed_step = snapshot_value(@last_failed_step)
          @last_prepared_input = snapshot_value(@last_prepared_input)
        end

        def detach_split_step_metadata!
          @created_at = snapshot_value(@created_at)
          @updated_at = snapshot_value(@updated_at)
          @execution_namespace = snapshot_value(@execution_namespace)
          @seed_digest = snapshot_value(@seed_digest)
          @router_next_transition = snapshot_value(@router_next_transition)
        end

        def snapshot_split_step_ledger
          Budget::Ledger.new(
            limits: snapshot_value(@ledger.limits),
            consumed: snapshot_value(@ledger.consumed)
          )
        end

        def split_step_boundary_active? = !@split_step_phase.nil?
      end
    end
  end
end
