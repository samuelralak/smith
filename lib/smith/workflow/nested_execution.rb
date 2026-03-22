# frozen_string_literal: true

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
        child = child_class.new(context: @context.dup, ledger: @ledger, created_at: @created_at)
        child.instance_variable_set(:@execution_namespace, @execution_namespace)
        child.instance_variable_set(:@inherited_deadline, wall_clock_deadline)
        child.instance_variable_set(:@inherited_scoped_artifacts, Smith.scoped_artifacts)
        child
      end

      def handle_child_result(child_result)
        failed_step = child_result.steps.find { |s| s.key?(:error) }
        raise WorkflowError, "nested workflow failed: #{failed_step[:error]&.message}" if failed_step

        child_result.output
      end
    end
  end
end
