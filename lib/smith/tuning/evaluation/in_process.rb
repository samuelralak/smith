# frozen_string_literal: true

module Smith
  module Tuning
    module Evaluation
      # Experimental. The seam as Smith runs it in one process (slice 5a
      # design, section 2): each evaluation is one eval run of the suite
      # (Smith::Evals.run with the samples, one trial each, the candidate and
      # the kind), so every metric call is a trial with its line, step
      # records, outcome, cost and resume; each reflection is
      # Reflection::Runner's recorded trial.
      #
      # A sample's score is the objective's value on its trial line; a
      # failed subject scores 0 by the outcome rule and an errored trial 0.
      # A trial the eval run stopped on (not_run: the budget ledger refused
      # it, or an error that stops every trial) did not run: it is no
      # metric call and not in the pass, and the eval run, called again
      # under the same key, runs it. The pass's provider calls and cost are
      # its eval run's summary's. The two free checks: every step of a
      # component the candidate changed sent the candidate's version (else
      # :candidate_not_sent), and feedback is asked only with `component:`
      # and only on training samples (else ArgumentError). The scorer's
      # feedback is read from the stored trial (Evals::Trial.from_line);
      # without any, the score's explanation stands in. A pass stops the
      # tuning run when its eval run met the cap (incomplete:
      # :cap_reached), failed (its reason code), was cancelled, or the
      # objective could not score a trial (:scorer_failed). O(T) in the
      # pass's trial lines.
      class InProcess
        # samples: the suite's selected samples by id; base_versions: the
        # seed's version of each tuned component.
        def initialize(suite:, scope:, store:, started_by:, objective:, samples:, train_ids:, base_versions:,
                       reflection:)
          @suite = suite
          @run = { scope:, store:, started_by: }
          @objective = objective
          @scorer = suite.scorers.find { _1.name == objective }&.scorer or
            raise ArgumentError, "objective names #{objective}, which the suite does not score"
          @samples = samples
          @train_ids = train_ids.to_set
          @base_versions = base_versions
          @reflection = reflection
        end

        def evaluate(candidate, sample_ids:, kind:, key:, component: nil)
          blind!(sample_ids) if component
          run = Evals.run(@suite, idempotency_key: key, samples: sample_ids, trials: 1, candidate:, kind:, **@run)
          lines = run.record.each_trial.reject { _1["outcome"] == "not_run" }.to_h { [_1["sample_id"], _1] }
          passed(run, lines, sample_ids, candidate, component)
        end

        def reflect(message, trial_id:) = @reflection.call(message, trial_id:)

        private

        # lines: the eval run's trial lines that ran, by sample id.
        def passed(run, lines, sample_ids, candidate, component)
          stop = stopped(run, lines.values, candidate)
          ran = sample_ids.select { lines.key?(_1) }.to_h { [_1, sample(lines[_1], component)] }
          Pass.new(eval_run_id: run.eval_run_id, samples: ran, metric_calls: lines.size, **spent(run), stop:,
                   complete: ran.size == sample_ids.size)
        end

        # The pass's provider calls and cost: its eval run's summary's.
        def spent(run)
          usage = run.summary.fetch("usage")
          { provider_calls: usage["provider_calls"], cost_nanos: usage["cost_nanos"],
            cost_complete: usage["cost_complete"] }
        end

        def blind!(sample_ids)
          other = sample_ids.find { !@train_ids.include?(_1) }
          raise ArgumentError, "feedback is asked on training samples only; #{other} is not one" if other
        end

        def stopped(run, lines, candidate)
          case run.status
          when :incomplete then :cap_reached
          when :failed then run.summary.dig("stop", "reason", "code").to_sym
          when :cancelled then :cancelled
          else
            return :candidate_not_sent unless sent?(lines, candidate)

            :scorer_failed if lines.any? { _1["outcome"] != "error" && !scored?(_1) }
          end
        end

        # Every step of a changed component carries the candidate's version.
        def sent?(lines, candidate)
          changed = candidate.versions.reject { |id, version| @base_versions[id] == version }
          lines.flat_map { _1["steps"] || [] }.flat_map { _1["components"] || [] }.all? do |sent|
            !changed.key?(sent["id"]) || changed[sent["id"]] == sent["version"]
          end
        end

        def scored?(line) = line.dig("scores", @objective, "status") == "scored"

        def sample(line, component)
          score = scored?(line) ? line.dig("scores", @objective, "value").to_f : 0.0
          return Sample.new(score:, feedback: nil, steps: nil) unless component

          Sample.new(score:, feedback: feedback(line, component), steps: line["steps"] || [])
        end

        def feedback(line, component)
          return if line["outcome"] == "error"

          given = @scorer.feedback(@samples.fetch(line["sample_id"]), Evals::Trial.from_line(line), component:)
          given || line.dig("scores", @objective, "explanation")
        end
      end
    end
  end
end
