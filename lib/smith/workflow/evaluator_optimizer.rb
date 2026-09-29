# frozen_string_literal: true

require "json"

require_relative "agent_result"
require_relative "execution_result_snapshot"
require_relative "optimization_state"

module Smith
  class Workflow
    module EvaluatorOptimizer
      private

      def execute_optimization_step(transition, prepared_input: nil)
        state = OptimizationState.new(transition.optimization_config, prepared_input)
        state.generator_class = resolve_registered_agent!(
          state.config[:generator],
          workflow_class: self.class,
          transition_name: transition.name,
          role: :generator
        )
        state.evaluator_class = resolve_registered_agent!(
          state.config[:evaluator],
          workflow_class: self.class,
          transition_name: transition.name,
          role: :evaluator
        )
        pend_evaluations
        run_optimization_loop(state)
      end

      def run_optimization_loop(state)
        state.config[:max_rounds].times do |round|
          # The overlay scopes every trace and usage fact from this round's
          # generator and evaluator calls to the round that produced them.
          result = Attribution.with(round: round) { run_optimization_round(state, round) }
          return result if result
        end

        handle_exit(state, :on_exhaustion,
                    "optimization exhausted #{state.config[:max_rounds]} rounds without acceptance")
      end

      def run_optimization_round(state, round)
        generate_candidate!(state, round)
        rejection = before_eval_rejection(state)
        evaluation = rejection || normalize_evaluation(evaluate_candidate(state))
        validate_evaluation_structure!(evaluation)
        validate_evaluation_fields!(evaluation, state.config)
        record_evaluation(state, evaluation, round, rejection ? :before_eval : :evaluator)

        return state.candidate if evaluation[:accept]

        if evaluation[:converged]
          return handle_exit(state, :on_converged,
                             "optimization converged without acceptance after round #{round + 1}")
        end

        threshold_exit = check_improvement_threshold!(evaluation, state, round)
        return threshold_exit if threshold_exit

        state.last_score = evaluation[:score]
        state.feedback = evaluation[:feedback]
        nil
      end

      # Each valid round's evaluation, in round order: the round, whether the
      # evaluator or a before_eval rejection gave it, and the verdict as
      # normalized, copied and frozen so neither the loop nor a host holding a
      # record can change it. Recorded before any exit, so the verdict that
      # ends the loop (accepted, converged, or under the threshold) is kept.
      # The loop's state carries a frozen copy, so a callable reads the
      # verdicts so far and cannot rewrite the step's.
      def record_evaluation(state, evaluation, round, source)
        records = @pending_evaluations.values.last
        record = { round: round, source: source, verdict: frozen_verdict(evaluation) }.freeze
        within_step_record_limits!(@pending_evaluations.values.flatten(1) << record)
        records << record
        state.evaluations = records.dup.freeze
      end

      # The verdicts ride on the step's record, which a split step snapshots
      # under ExecutionResultSnapshot's limits. A round whose verdict would
      # take the step's verdicts past them fails here, the same way in every
      # run mode, and the verdicts already recorded still fit a failed step's
      # record.
      def within_step_record_limits!(records)
        ExecutionResultSnapshot.new({ evaluations: records }).call
      rescue WorkflowError => e
        raise WorkflowError, "evaluations exceed a step record's limits: #{e.message}"
      end

      # A verdict holds JSON values only, as a provider's structured output
      # does: anything else (an object a before_eval returned, a key that is
      # not a String or Symbol, a non-finite Float) fails the round here, the
      # same way in every run mode, rather than when a split step snapshots it.
      def frozen_verdict(value)
        case value
        when Hash then value.to_h { |key, nested| [verdict_key(key), frozen_verdict(nested)] }.freeze
        when Array then value.map { |nested| frozen_verdict(nested) }.freeze
        when String then StringSnapshot.copy(value, freeze: true)
        else verdict_scalar(value)
        end
      end

      def verdict_scalar(value)
        case value
        when Float then finite_verdict_number(value)
        when Symbol, Integer, true, false, nil then value
        else raise WorkflowError, "evaluation must hold JSON values; got #{value.class}"
        end
      end

      def verdict_key(key)
        return key if key.is_a?(Symbol)
        return StringSnapshot.copy(key, freeze: true) if key.is_a?(String)

        raise WorkflowError, "evaluation keys must be Strings or Symbols; got #{key.class}"
      end

      def finite_verdict_number(value)
        return value if value.finite?

        raise WorkflowError, "evaluation must hold finite numbers; got #{value}"
      end

      # An optimize step's record carries every verdict its loops recorded
      # under :evaluations, whether the step completed or failed, each naming
      # the attempt that gave it (`@step_attempt`, the retry policy's): a step
      # `retry_on` runs again starts its loop afresh, rounds counting from 0
      # again, and an earlier attempt's verdicts were given and paid for all
      # the same. The key is there whenever a loop ran; a step that failed
      # before its loop (an agent not registered, a guardrail) and any other
      # step have none. The carrier is transient: the loop's list keyed by its
      # attempt, cleared once the step's record is committed or its failure
      # captured, and at every step's start.
      def pend_evaluations
        (@pending_evaluations ||= {})[@step_attempt || 1] = []
      end

      def fold_pending_evaluations(step)
        return unless @pending_evaluations

        step[:evaluations] = @pending_evaluations.flat_map do |attempt, records|
          records.map { |record| { attempt: attempt, **record }.freeze }
        end.freeze
      end

      # :raise => WorkflowError(message); :return_last => state.candidate;
      # callable => mode.call(state). Default :raise preserves legacy
      # behavior for hosts that don't opt in to graceful exits.
      def handle_exit(state, mode_key, message)
        mode = state.config[mode_key]
        case mode
        when :raise        then raise WorkflowError, message
        when :return_last  then state.candidate
        else
          mode.call(state)
        end
      end

      # Real RubyLLM schema-bound responses come back as Hash with String
      # keys. The validate_evaluation_* helpers below expect symbol keys
      # (test stubs use symbol keys, masking the gap). String input also
      # arrives when an evaluator stubs raw JSON. Normalize to a uniform
      # symbol-keyed Hash so the validators stay clean and the rest of
      # the loop can use `evaluation[:accept]` semantics without caring
      # which provider returned the payload.
      #
      # Pure-Ruby deep-symbolize: Smith doesn't depend on ActiveSupport,
      # so `deep_symbolize_keys` isn't available. The recursion mirrors
      # what `Hash#transform_keys` plus a nested-Hash walk would do.
      def normalize_evaluation(evaluation)
        case evaluation
        when Hash
          deep_symbolize_evaluation(evaluation)
        when String
          parsed = parse_evaluation_json(evaluation)
          parsed.is_a?(Hash) ? parsed : evaluation
        else
          evaluation
        end
      end

      def deep_symbolize_evaluation(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested), out|
            sym_key = key.is_a?(String) ? key.to_sym : key
            out[sym_key] = deep_symbolize_evaluation(nested)
          end
        when Array
          value.map { |item| deep_symbolize_evaluation(item) }
        else
          value
        end
      end

      def generate_candidate!(state, round)
        input = prepare_generator_input(state.prepared_input, round, state.candidate, state.feedback)
        result = invoke_agent_with_budget(state.generator_class, input)
        state.candidate = result
      end

      def evaluate_candidate(state)
        input = build_evaluator_input(state)
        invoke_with_evaluator_schema(state.evaluator_class, state.config[:evaluator_schema], input)
      end

      # evaluator_context: :inject_state appends the candidate as a
      # user turn to the prepared_input the generator received, so the
      # evaluator sees the same seed_messages + inject_state context.
      # Default nil keeps the legacy candidate-only payload.
      def build_evaluator_input(state)
        content = candidate_content(state.candidate)
        return [{ role: :user, content: }] unless state.config[:evaluator_context] == :inject_state

        prior = Array(state.prepared_input).dup
        prior.push(role: :user, content:)
      end

      # A structured candidate (an output_schema agent's Hash or Array) gets
      # the JSON serialisation the provider boundary applies; text stays as is.
      def candidate_content(candidate)
        candidate.is_a?(Hash) || candidate.is_a?(Array) ? json_message_content(candidate) : candidate.to_s
      end

      # Runs after candidate generation, before evaluator invocation.
      # Receives (state, @context); @context is mutable. A returned Hash
      # whose accept (Symbol or String key) is false is the round's
      # evaluation, validated like evaluator output, and the evaluator is
      # not called; any other return value is discarded. Raised exceptions
      # bubble through the standard step failure path.
      def before_eval_rejection(state)
        callback = state.config[:before_eval]
        return unless callback

        verdict = callback.call(state, @context)
        return unless verdict.is_a?(Hash)

        evaluation = normalize_evaluation(verdict)
        evaluation if evaluation.key?(:accept) && evaluation[:accept].equal?(false)
      end

      def invoke_with_evaluator_schema(evaluator_class, schema, input)
        invoke_agent_with_budget(evaluator_class, input, output_schema: schema)
      end

      def invoke_agent_with_budget(agent_class, prepared_input, output_schema: agent_class.output_schema)
        Thread.current[:smith_last_agent_result] = nil
        clear_failed_billable_attempts
        with_agent_context(agent_class) do
          invoke_with_call_ledger(agent_class, prepared_input, output_schema:)
        end
      ensure
        clear_failed_billable_attempts
      end

      def invoke_with_call_ledger(agent_class, prepared_input, output_schema:)
        ledger = effective_call_ledger
        reserved = reserve_serial_budget(ledger, agent_budget: agent_class&.budget)
        begin
          result = invoke_agent(agent_class, prepared_input, output_schema:)
          agent_result = result.is_a?(AgentResult) ? result : nil
          reconcile_branch_budget(ledger, reserved, agent_result: agent_result)
          reserved = nil
          agent_result ? agent_result.content : result
        ensure
          settle_budget_on_failure(ledger, reserved, Thread.current[:smith_last_agent_result]) if reserved
          Thread.current[:smith_last_agent_result] = nil
        end
      end

      # Returns nil when the threshold doesn't trip. When it does,
      # routes through on_threshold and returns the resulting value
      # (non-nil terminates the loop with that as the step output).
      def check_improvement_threshold!(evaluation, state, round)
        unless stop_for_threshold?(evaluation[:score], state.last_score, state.config[:improvement_threshold])
          return nil
        end

        handle_exit(state, :on_threshold,
                    "optimization improvement below threshold after round #{round + 1}")
      end

      def parse_evaluation_json(evaluation)
        JSON.parse(evaluation, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end

      def prepare_generator_input(prepared_input, round, prior_candidate, feedback)
        return prepared_input if round.zero?

        (prepared_input&.dup || []).push(
          { role: :assistant, content: candidate_content(prior_candidate) },
          {
            role: :user,
            content: "[smith:refinement-round] #{round + 1}\n[smith:evaluator-feedback]\n#{feedback}"
          }
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
