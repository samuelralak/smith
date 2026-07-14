# frozen_string_literal: true

require_relative "usage_entry"

module Smith
  class Workflow
    module NestedExecution
      private

      def execute_nested_workflow(transition)
        check_deadline!
        child = build_child_workflow(transition.workflow_class)
        child_result = run_child_workflow(child)
        handle_child_result(child_result)
      end

      def run_child_workflow(child)
        child.run!
      rescue Smith::Error => e
        raise WorkflowError, "nested workflow failed: #{e.message}"
      end

      def build_child_workflow(child_class)
        @split_step_active_execution_authorization&.verify_workflow!(child_class)
        child = child_class.new(context: @context.dup, ledger: @ledger, created_at: @created_at)
        unless child.instance_of?(child_class)
          raise WorkflowError, "nested workflow constructor returned #{child.class} instead of #{child_class}"
        end

        @split_step_active_execution_authorization&.verify_workflow!(child_class)
        child.instance_variable_set(:@execution_namespace, @execution_namespace)
        child.instance_variable_set(:@inherited_deadline, wall_clock_deadline)
        child.instance_variable_set(:@inherited_scoped_artifacts, Smith.scoped_artifacts)
        child.instance_variable_set(
          :@split_step_active_execution_authorization,
          @split_step_active_execution_authorization
        )
        child
      end

      # Roll up child totals AND usage_entries BEFORE the failed-step
      # check raises. Previously the rollup only fired on child success
      # — billable agent work inside a failed child was silently
      # dropped from the parent's totals/entries. Simple aggregate drift
      # checks can miss this when parent rollups and entries undercount
      # the same way. Roll up first, then re-raise, so the parent's
      # terminal state reflects the child's billable work even when the
      # child failed.
      def handle_child_result(child_result)
        roll_up_child_totals(child_result)

        failed_step = child_result.steps.find { |s| s.key?(:error) }
        raise WorkflowError, "nested workflow failed: #{failed_step[:error]&.message}" if failed_step

        child_result.output
      end

      # `@usage_mutex` is eagerly initialized in `Workflow#initialize`
      # AND `Workflow#restore_state`, so it's always present. Single
      # synchronize block updates totals + entries together, matching
      # the lifecycle.rb `record_usage` pattern.
      #
      # Defensive deep-copy via `from_h(snapshot_value(entry.to_h))`:
      # `Struct#dup` is shallow (shares mutable string fields like
      # `usage_id`/`model`), and aliasing child entries into multiple
      # parents could let later mutations corrupt earlier parents.
      def roll_up_child_totals(child_result)
        child_entries = (child_result.usage_entries || []).map do |entry|
          Workflow::UsageEntry.from_h(snapshot_value(entry.to_h))
        end

        @usage_mutex.synchronize do
          @total_cost = (@total_cost || 0.0) + (child_result.total_cost || 0.0)
          @total_tokens = (@total_tokens || 0) + (child_result.total_tokens || 0)
          @usage_entries.concat(child_entries)
        end
      end
    end
  end
end
