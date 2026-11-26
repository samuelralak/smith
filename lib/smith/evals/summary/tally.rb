# frozen_string_literal: true

require_relative "../spend"

module Smith
  module Evals
    module Summary
      # Internal. One pass over a run's trial lines: every line's spend, and
      # each trial's effective line (its highest trial_revision) kept as the
      # few facts the summary reads, so memory is O(T) for T trials.
      class Tally
        OUTCOMES = %w[scored subject_failed limit_hit unscored error not_run].freeze
        # What the summary reads of an effective line.
        Facts = Data.define(:revision, :sample_id, :index, :outcome, :reason, :latency, :attempts, :scores)

        def initialize
          @spend = Spend.new
          @effective = {}
          @sample_cost = Hash.new(0)
          @models = Hash.new(0)
          @attempts = @tool_calls = 0
        end

        def add(line)
          spent(line)
          kept = @effective[line.fetch("trial_id")]
          @effective[line["trial_id"]] = facts(line) if kept.nil? || line.fetch("trial_revision") > kept.revision
        end

        # The effective lines' facts, in trial index order (stable).
        def trials = @effective.values.each_with_index.sort_by { |trial, at| [trial.index, at] }.map(&:first)

        def count(outcome) = @effective.each_value.count { _1.outcome == outcome }

        # outcomes and causes: the trials that never started are not_run,
        # under the stop's code (cancelled when no stop names one).
        def outcomes(planned, stop)
          outcomes, causes = counted
          missing = planned - @effective.size
          outcomes["not_run"] += missing
          causes["not_run"][stop&.dig("reason", "code") || "cancelled"] += missing if missing.positive?
          { "outcomes" => outcomes, "causes" => causes.transform_values(&:to_h) }
        end

        def retries
          { "trials_retried" => @effective.each_value.count { _1.attempts > 1 },
            "attempts_retried" => @effective.each_value.sum { _1.attempts - 1 } }
        end

        # Every line's usage; per trial over the trials that ran; per sample
        # over the samples whose every planned trial ran, all their lines
        # included.
        def usage(per_sample)
          usage = @spend.usage
          usage.except("by_model").merge(
            "cost_per_trial_nanos" => half_up(Rational(usage["cost_nanos"], [1, ran.size].max)),
            **per_sample(per_sample), "by_model" => usage["by_model"]
          )
        end

        # From each trial's final attempt: the mean, the type 7 p50 and p90
        # (exact, at 1/2 and 9/10), each rounded half up, and the largest.
        def latency
          values = ran.map(&:latency).sort
          return if values.empty?

          { "mean" => half_up(Rational(values.sum, values.size)), "p50" => half_up(type7(values, Rational(1, 2))),
            "p90" => half_up(type7(values, Rational(9, 10))), "max" => values.last }
        end

        def counts
          { "agent_attempts" => @attempts, "tool_calls" => @tool_calls,
            "tool_calls_per_trial" => Rational(@tool_calls, [1, ran.size].max).to_f }
        end

        # Every line's steps by model, then provider (UTF-16, unknown first).
        def models
          @models.sort_by { |(model, provider), _count| [order(model), order(provider)] }
                 .map { |(model, provider), count| { "model" => model, "provider" => provider, "attempts" => count } }
        end

        private

        def ran = @effective.each_value.reject { _1.outcome == "not_run" }

        def spent(line)
          @spend.add_usage(line.fetch("usage"))
          @sample_cost[line.fetch("sample_id")] += line.dig("usage", "cost_nanos")
          @attempts += line.dig("counts", "agent_attempts")
          @tool_calls += line.dig("counts", "tool_calls")
          line.fetch("steps").each { @models[_1.values_at("model", "provider")] += 1 }
        end

        # Each outcome's count, and each reason code's under each outcome
        # but scored, over the effective lines.
        def counted
          outcomes = OUTCOMES.to_h { [_1, 0] }
          causes = OUTCOMES.drop(1).to_h { [_1, Hash.new(0)] }
          @effective.each_value do |trial|
            outcomes[trial.outcome] += 1
            causes[trial.outcome][trial.reason] += 1 unless trial.outcome == "scored"
          end
          [outcomes, causes]
        end

        def per_sample(per_sample)
          finished = ran.group_by(&:sample_id).select { |_id, trials| trials.size == per_sample }.keys
          costed = finished.sum { @sample_cost[_1] }
          { "samples_costed" => finished.size, "cost_per_sample_nanos" => per(costed, finished.size, 1),
            "cost_per_1000_samples_nanos" => per(costed, finished.size, 1000) }
        end

        def facts(line)
          scores = line.fetch("scores").transform_values { _1.values_at("status", "passed", "value") }
          Facts.new(revision: line["trial_revision"], sample_id: line["sample_id"], index: line.fetch("trial_index"),
                    outcome: line.fetch("outcome"), reason: line.dig("reason", "code"), latency: line["latency_ms"],
                    attempts: line.fetch("attempts").size, scores:)
        end

        def per(costed, samples, scale) = samples.zero? ? nil : half_up(Rational(costed * scale, samples))

        def type7(sorted, quantile)
          h = (sorted.size - 1) * quantile
          low = h.floor
          sorted[low] + ((h - low) * (sorted[[low + 1, sorted.size - 1].min] - sorted[low]))
        end

        def half_up(value) = (value + Rational(1, 2)).floor

        def order(name) = name.nil? ? [0, ""] : [1, name.encode(Encoding::UTF_16BE).b]
      end
    end
  end
end
