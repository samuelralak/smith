# frozen_string_literal: true

require_relative "execution_binding_collector"
require_relative "execution_workflow_snapshot"

module Smith
  class Workflow
    module SplitStepPersistence
      class ExecutionBindingSnapshot
        MAX_NESTED_WORKFLOWS = 128
        MAX_TRANSITIONS = 10_000

        def self.capture(transition, workflow_class:)
          new(transition, workflow_class:).capture
        end

        def initialize(transition, workflow_class:)
          @transition = transition
          @workflow_class = workflow_class
          @bindings = ExecutionBindingCollector.new
          @visited_workflows = {}.compare_by_identity
          @visited_workflows[workflow_class] = true
          @workflow_snapshots = {}.compare_by_identity
          @workflow_queue = []
          @workflow_queue_index = 0
          @transition_count = 0
        end

        def capture
          capture_transition(@transition, workflow_class: @workflow_class)
          drain_workflow_queue
          @bindings.resolve!
          @bindings.freeze
          @workflow_snapshots.freeze
          freeze
        end

        def fetch!(name, workflow_class:, transition_name:, role:)
          @bindings.fetch!(name, workflow_class:, transition_name:, role:)
        end

        def each_agent_binding(&)
          @bindings.each(&)
        end

        def verify_workflow!(workflow_class)
          snapshot = @workflow_snapshots.fetch(workflow_class) do
            raise WorkflowError, "execution authorization does not contain nested workflow #{workflow_class}"
          end
          snapshot.verify!
        end

        private

        def capture_transition(transition, workflow_class:)
          return unless transition

          visit_transition!
          @bindings.capture(transition, workflow_class:)
          enqueue_nested_workflow(transition.workflow_class)
        end

        def enqueue_nested_workflow(workflow_class)
          return unless workflow_class
          return if @visited_workflows.key?(workflow_class)

          @visited_workflows[workflow_class] = true
          if @visited_workflows.length > MAX_NESTED_WORKFLOWS
            raise WorkflowError,
                  "execution authorization exceeds maximum nested workflows #{MAX_NESTED_WORKFLOWS}"
          end

          @workflow_queue << workflow_class
        end

        def drain_workflow_queue
          while @workflow_queue_index < @workflow_queue.length
            workflow_class = @workflow_queue.fetch(@workflow_queue_index)
            @workflow_queue_index += 1
            @workflow_snapshots[workflow_class] = ExecutionWorkflowSnapshot.capture(workflow_class) do |transition|
              capture_transition(transition, workflow_class:)
            end
          end
        end

        def visit_transition!
          @transition_count += 1
          return if @transition_count <= MAX_TRANSITIONS

          raise WorkflowError, "execution authorization exceeds maximum transitions #{MAX_TRANSITIONS}"
        end
      end
    end
  end
end
