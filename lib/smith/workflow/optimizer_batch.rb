# frozen_string_literal: true

require "json"

module Smith
  class Workflow
    # Batch mode on an optimize step (`optimize ..., mode: :batch`). Each of
    # the loop's calls, a round's generator and then its evaluator, is a
    # batch request of its own, as the evaluator reads what the generator
    # wrote. The call is captured as an agent step's is (BatchExecution), the
    # attempt ends, and the run waits for the result, its pending batch
    # keeping the loop's progress (`progress`: the round, the call it waits for,
    # the candidate, feedback and last score, and the verdicts so far, as
    # JSON gives them). A delivery runs the step again at its attempt, and
    # the loop goes on from that progress: the call it waited for takes its
    # result, and the next call is batched in turn, so each call is made,
    # and charged, once. The step's mode is asked at each call.
    module OptimizerBatch
      ROLES = %w[generator evaluator].freeze
      PROGRESS_FIELDS = %w[candidate evaluations feedback last_score role round].freeze
      RECORD_FIELDS = %w[round source verdict].freeze
      SOURCES = %w[evaluator before_eval].freeze
      ATTEMPT = /\A[1-9]\d*\z/
      CAPTURED = :smith_optimizer_batch
      private_constant :ROLES, :PROGRESS_FIELDS, :RECORD_FIELDS, :SOURCES, :ATTEMPT, :CAPTURED

      private

      # The step's output, or the call its loop batched, thrown out of the
      # loop for the step to queue.
      def optimizer_batch_output(transition, &)
        return yield unless transition.optimized? && transition.batches?

        catch(CAPTURED, &)
      end

      # One of the loop's calls (`role` "generator" or "evaluator"): batched
      # when the step's mode says so and no result of it is being
      # delivered, else made as ever.
      def optimizer_call(transition, state, round, role, input)
        if transition.batches? && !batch_result_due? && batch_mode_for(transition) == :batch
          throw(CAPTURED, batch_optimizer_call(transition, state, round, role, input))
        end

        agent_class, output_schema = optimizer_agent(state, role)
        invoke_agent_with_budget(agent_class, input, output_schema:)
      end

      def optimizer_agent(state, role)
        return [state.generator_class, state.generator_class.output_schema] if role == "generator"

        [state.evaluator_class, state.config[:evaluator_schema]]
      end

      # The call's request, admitted and held as an agent step's is, under
      # a wait of its own: the round and the call tell its token apart. A
      # stored run whose progress would take it past persistence_max_bytes
      # fails here, before anything is queued.
      def batch_optimizer_call(transition, state, round, role, input)
        agent_class, output_schema = optimizer_agent(state, role)
        progress = optimizer_progress(state, round, role)
        StepCompletion.instance_method(:check_result_storable!).bind_call(self, progress)
        capture = lambda do
          admit_batch_call { reserve_serial_budget(effective_call_ledger, agent_budget: agent_class&.budget) }
          with_agent_context(agent_class) { capture_batch_request(agent_class, input, output_schema:) }
        end
        send_batch(transition, { nil => capture }, position: [round, role], progress:)
      end

      # What a delivery's loop goes on from, as JSON gives it.
      def optimizer_progress(state, round, role)
        progress = { "round" => round, "role" => role, "candidate" => state.candidate, "feedback" => state.feedback,
                     "last_score" => state.last_score, "evaluations" => kept_evaluations }
        Batch.deep_freeze(JSON.parse(JSON.generate(progress)))
      rescue JSON::GeneratorError, JSON::NestingError, Encoding::UndefinedConversionError
        raise WorkflowError, "an optimize step waits for a batch only with JSON values for its candidate and feedback"
      end

      # Every attempt's verdicts so far, by attempt.
      def kept_evaluations
        @pending_evaluations.to_h do |attempt, records|
          [attempt.to_s, records.map { |record| record.merge(source: record[:source].to_s) }]
        end
      end

      # The round and call the loop goes on from, with its state and
      # verdicts as the pending batch kept them; none unless a result of
      # this step's loop is being delivered.
      def resume_optimizer_progress(state)
        progress = @pending_batch&.fetch("progress", nil) if delivering_batch?
        return unless progress

        state.candidate, state.feedback, state.last_score =
          snapshot_value(progress.values_at("candidate", "feedback", "last_score"))
        restore_kept_evaluations(progress.fetch("evaluations"))
        state.evaluations = @pending_evaluations.values.last.dup.freeze
        progress.values_at("round", "role")
      end

      # Kept verdicts back as the loop records them, in attempt order, the
      # attempt under way last.
      def restore_kept_evaluations(kept)
        restored = kept.to_h do |attempt, records|
          [attempt.to_i, records.map { kept_record(_1) }]
        end
        @pending_evaluations = @pending_evaluations.merge(restored).sort.to_h
      end

      def kept_record(record)
        { round: record.fetch("round"), source: record.fetch("source").to_sym,
          verdict: frozen_verdict(normalize_evaluation(record.fetch("verdict"))) }.freeze
      end

      # The agent whose call an optimize step's pending batch waited for.
      def optimizer_batch_agent(transition, progress)
        role = progress.fetch("role").to_sym
        resolve_registered_agent!(transition.optimization_config.fetch(role), workflow_class: self.class,
                                                                              transition_name: transition.name, role:)
      end

      # A stored pending batch's `progress` (BatchWait): a call of a
      # round the step runs, a last score that is a number or none, and kept
      # verdicts of attempts up to the batch's.
      def optimizer_progress?(transition, progress, attempt)
        progress.is_a?(Hash) && progress.keys.sort == PROGRESS_FIELDS && optimizer_position?(transition, progress) &&
          (progress["last_score"].nil? || progress["last_score"].is_a?(Numeric)) &&
          kept_evaluations?(progress["evaluations"], attempt)
      end

      def optimizer_position?(transition, progress)
        round = progress["round"]
        ROLES.include?(progress["role"]) && round.is_a?(Integer) &&
          round.between?(0, transition.optimization_config.fetch(:max_rounds) - 1)
      end

      def kept_evaluations?(kept, attempt)
        kept.is_a?(Hash) && kept.all? do |key, records|
          key.is_a?(String) && ATTEMPT.match?(key) && key.to_i <= attempt && records.is_a?(Array) &&
            records.all? { kept_record?(_1) }
        end
      end

      def kept_record?(record)
        record.is_a?(Hash) && record.keys.sort == RECORD_FIELDS && record["round"].is_a?(Integer) &&
          !record["round"].negative? && SOURCES.include?(record["source"]) && record["verdict"].is_a?(Hash)
      end
    end
  end
end
