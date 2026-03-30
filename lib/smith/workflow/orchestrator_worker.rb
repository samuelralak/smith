# frozen_string_literal: true

require "json"
require "securerandom"

module Smith
  class Workflow
    module OrchestratorWorker
      OrchestrationState = Struct.new(
        :config, :prepared_input, :orchestrator_class, :worker_class, :worker_results
      ) do
        def initialize(config, prepared_input)
          super(config, prepared_input, nil, nil, nil)
        end
      end

      WorkerExecution = Struct.new(:execution_id, :task, :output) do
        def self.run(worker_class, task, schema, budget_runner)
          new(SecureRandom.uuid, task, budget_runner.call(worker_class, task, schema))
        end
      end

      private

      def dispatch_step(transition, prepared_input: nil)
        if transition.parallel? then execute_parallel_step(transition, prepared_input: prepared_input)
        elsif transition.nested? then execute_nested_workflow(transition)
        elsif transition.optimized? then execute_optimization_step(transition, prepared_input: prepared_input)
        elsif transition.orchestrated? then execute_orchestration_step(transition, prepared_input: prepared_input)
        elsif transition.deterministic? then execute_deterministic_step(transition)
        else execute_serial_step(transition, prepared_input: prepared_input)
        end
      end

      def execute_orchestration_step(transition, prepared_input: nil)
        state = OrchestrationState.new(transition.orchestrator_config, prepared_input)
        state.orchestrator_class = Agent::Registry.fetch!(
          state.config[:orchestrator],
          workflow_class: self.class,
          transition_name: transition.name,
          role: :orchestrator
        )
        state.worker_class = Agent::Registry.fetch!(
          state.config[:worker],
          workflow_class: self.class,
          transition_name: transition.name,
          role: :worker
        )
        run_orchestration_loop(state)
      end

      def run_orchestration_loop(state)
        state.config[:max_delegation_rounds].times do |round|
          result = run_orchestration_round(state, round)
          return result if result
        end

        raise WorkflowError,
              "orchestration exhausted #{state.config[:max_delegation_rounds]} rounds without final output"
      end

      def run_orchestration_round(state, round)
        decision = call_orchestrator(state, round)
        validate_orchestrator_decision!(decision)

        return validated_final(decision[:final], state.config) if decision.key?(:final)
        raise WorkflowError, "orchestrator stopped: #{decision[:stop]}" if decision.key?(:stop)

        validate_tasks!(decision[:tasks], state.config)
        state.worker_results = execute_workers(state, decision[:tasks])
        nil
      end

      def call_orchestrator(state, round)
        input = prepare_orchestrator_input(state.prepared_input, round, state.worker_results)
        invoke_agent_with_budget(state.orchestrator_class, input)
      end

      def execute_workers(state, tasks)
        runner = method(:run_worker_with_schema)
        tasks.map do |task|
          validate_task!(task, state.config[:task_schema])
          execution = WorkerExecution.run(state.worker_class, task, state.config[:worker_output_schema], runner)
          validate_worker_output!(execution.output, state.config[:worker_output_schema])
          { execution_id: execution.execution_id, task: execution.task, output: execution.output }
        end
      end

      def run_worker_with_schema(worker_class, task, worker_output_schema)
        input = [{ role: :user, content: task.to_json }]
        original_schema = worker_class.output_schema
        worker_class.output_schema(worker_output_schema)
        invoke_agent_with_budget(worker_class, input)
      ensure
        worker_class.output_schema(original_schema)
      end

      def prepare_orchestrator_input(prepared_input, round, worker_results)
        return prepared_input if round.zero?

        (prepared_input&.dup || []).push(
          { role: :system, content: "[smith:orchestration-round] #{round + 1}" },
          { role: :user, content: "[smith:worker-results]\n#{worker_results.to_json}" }
        )
      end

      def validate_orchestrator_decision!(output)
        raise WorkflowError, "orchestrator output must be a Hash" unless output.is_a?(Hash)
        return if %i[tasks final stop].one? { |k| output.key?(k) }

        raise WorkflowError, "orchestrator must emit exactly one of :tasks, :final, or :stop"
      end

      def validate_tasks!(tasks, config)
        raise WorkflowError, "orchestrator :tasks must be an Array" unless tasks.is_a?(Array)
        return unless tasks.length > config[:max_workers]

        raise WorkflowError, "orchestrator tasks (#{tasks.length}) exceeds max_workers (#{config[:max_workers]})"
      end

      def validate_task!(task, schema)
        check_schema_keys!(task, schema, "worker task")
      end

      def validate_worker_output!(output, schema)
        check_schema_keys!(output, schema, "worker output")
      end

      def validated_final(final, config)
        check_schema_keys!(final, config[:final_output_schema], "final output")
        final
      end

      def check_schema_keys!(data, schema, label)
        raise WorkflowError, "#{label} must be a Hash" unless data.is_a?(Hash)
        return unless schema.respond_to?(:required_keys)

        missing = schema.required_keys.reject { |k| data.key?(k) }
        raise WorkflowError, "#{label} missing required keys: #{missing.join(", ")}" unless missing.empty?
      end
    end
  end
end
