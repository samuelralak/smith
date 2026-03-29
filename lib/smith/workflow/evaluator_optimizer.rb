# frozen_string_literal: true

module Smith
  class Workflow
    module EvaluatorOptimizer
      OptimizationState = Struct.new(
        :config, :prepared_input, :candidate, :feedback, :last_score, :generator_class, :evaluator_class
      ) do
        def initialize(config, prepared_input)
          super(config, prepared_input, nil, nil, nil, nil, nil)
        end
      end

      private

      def execute_optimization_step(transition, prepared_input: nil)
        state = OptimizationState.new(transition.optimization_config, prepared_input)
        state.generator_class = Agent::Registry.fetch!(
          state.config[:generator],
          workflow_class: self.class,
          transition_name: transition.name,
          role: :generator
        )
        state.evaluator_class = Agent::Registry.fetch!(
          state.config[:evaluator],
          workflow_class: self.class,
          transition_name: transition.name,
          role: :evaluator
        )
        run_optimization_loop(state)
      end

      def run_optimization_loop(state)
        state.config[:max_rounds].times do |round|
          result = run_optimization_round(state, round)
          return result if result
        end

        raise WorkflowError, "optimization exhausted #{state.config[:max_rounds]} rounds without acceptance"
      end

      def run_optimization_round(state, round)
        generate_candidate!(state, round)
        evaluation = evaluate_candidate(state)
        validate_evaluation_structure!(evaluation)
        validate_evaluation_fields!(evaluation, state.config)

        return state.candidate if evaluation[:accept]

        if evaluation[:converged]
          raise WorkflowError, "optimization converged without acceptance after round #{round + 1}"
        end

        check_improvement_threshold!(evaluation, state, round)
        state.last_score = evaluation[:score]
        state.feedback = evaluation[:feedback]
        nil
      end

      def generate_candidate!(state, round)
        input = prepare_generator_input(state.prepared_input, round, state.candidate, state.feedback)
        result = invoke_agent_with_budget(state.generator_class, input)
        state.candidate = result
      end

      def evaluate_candidate(state)
        invoke_with_evaluator_schema(
          state.evaluator_class, state.config[:evaluator_schema],
          [{ role: :user, content: state.candidate.to_s }]
        )
      end

      def invoke_with_evaluator_schema(evaluator_class, schema, input)
        original_schema = evaluator_class.output_schema
        evaluator_class.output_schema(schema)
        invoke_agent_with_budget(evaluator_class, input)
      ensure
        evaluator_class.output_schema(original_schema)
      end

      def invoke_agent_with_budget(agent_class, prepared_input)
        Thread.current[:smith_last_agent_result] = nil
        with_agent_context(agent_class) do
          invoke_with_call_ledger(agent_class, prepared_input)
        end
      end

      def invoke_with_call_ledger(agent_class, prepared_input)
        ledger = effective_call_ledger
        reserved = reserve_serial_budget(ledger, agent_budget: agent_class&.budget)
        begin
          result = invoke_agent(agent_class, prepared_input)
          agent_result = result.is_a?(AgentResult) ? result : nil
          reconcile_branch_budget(ledger, reserved, agent_result: agent_result)
          reserved = nil
          agent_result ? agent_result.content : result
        ensure
          settle_budget_on_failure(ledger, reserved, Thread.current[:smith_last_agent_result]) if reserved
          Thread.current[:smith_last_agent_result] = nil
        end
      end

      def check_improvement_threshold!(evaluation, state, round)
        return unless stop_for_threshold?(evaluation[:score], state.last_score, state.config[:improvement_threshold])

        raise WorkflowError, "optimization improvement below threshold after round #{round + 1}"
      end

      def prepare_generator_input(prepared_input, round, prior_candidate, feedback)
        return prepared_input if round.zero?

        (prepared_input&.dup || []).push(
          { role: :system, content: "[smith:refinement-round] #{round + 1}" },
          { role: :assistant, content: prior_candidate.to_s },
          { role: :user, content: "[smith:evaluator-feedback]\n#{feedback}" }
        )
      end

      def validate_evaluation_structure!(evaluation)
        raise WorkflowError, "evaluator output must be a Hash" unless evaluation.is_a?(Hash)
        raise WorkflowError, "evaluator output missing :accept" unless evaluation.key?(:accept)
        raise WorkflowError, "evaluator :accept must be boolean" unless [true, false].include?(evaluation[:accept])
      end

      def validate_evaluation_fields!(evaluation, config)
        unless evaluation[:accept] || evaluation[:feedback]
          raise WorkflowError, "evaluator must provide :feedback when not accepted"
        end
        return unless config[:improvement_threshold] && !evaluation[:score].is_a?(Numeric)

        raise WorkflowError, "evaluator must provide numeric :score when improvement_threshold is configured"
      end

      def stop_for_threshold?(current_score, last_score, threshold)
        threshold && last_score && current_score.is_a?(Numeric) && (current_score - last_score).abs < threshold
      end
    end
  end
end
