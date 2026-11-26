# frozen_string_literal: true

require_relative "../../attempt_observation"
require_relative "../../canonical_json"
require_relative "../../diagnostic_text"
require_relative "../../json_value"
require_relative "../spend"
require_relative "../store/clock"

module Smith
  module Evals
    class Record
      # Internal. One trial's line (contracts' trial.schema.json), from its
      # attempts, the last attempt's subject result and recorder, and its
      # outcome and scores (slice-1a design, 5.4 to 5.7).
      #
      # Its usage is every attempt's, a retry's included, by provider and
      # model; its counts, steps and recording are the last attempt's. Its
      # duration runs from the first attempt's start, its latency is the last
      # attempt's own time. Output over 64 KiB of canonical JSON, or with no
      # JSON form, is kept as null with the gap output_cut; kept state over
      # 1 MiB the same, state_cut. An error is kept by class, Smith's failure
      # family and a bounded message, which for a missing or refused key, no
      # credit or no permission is Smith's fixed text, whatever the error
      # said. O(B) in the bytes kept.
      module TrialLine
        FORMAT = "smith.evals.trial"
        MAX_OUTPUT_BYTES = 64 * 1024
        MAX_STATE_BYTES = 1024 * 1024
        FIXED = { "credentials_missing" => :credentials_missing, "key_refused" => :key_refused,
                  "out_of_credit" => :out_of_credit, "provider_permission" => :permission }.freeze

        # One attempt of a trial: its outcome (an Outcomes::Outcome), when
        # it started (wall clock, and monotonic seconds), how long it took,
        # what its recorder counted and the error that ended it, if any.
        Attempt = Data.define(:outcome, :started_at, :started, :duration_ms, :usage, :error)

        module_function

        # trial: the TrialSpec of the last attempt; attempts: every attempt,
        # in order; result: the last attempt's SubjectResult (nil when the
        # driver failed); scores: by scorer name, as the line keeps them.
        def build(trial, segment:, split:, attempts:, result:, scores:, recorder:)
          output, state, gaps = contents(result)
          { **head(trial, segment, split, attempts),
            "attempts" => attempts.each_with_index.map { |attempt, index| attempt(attempt, index + 1) },
            "subject" => subject(result), "output" => output, "state" => state, "error" => error(attempts.last),
            "scores" => scores, "usage" => usage(attempts), "counts" => recorder.counts, "steps" => recorder.steps,
            "recording" => recorder.recording(result, gaps:) }
        end

        # The output and kept state the line keeps, and the gaps for those it
        # could not.
        def contents(result)
          output, output_gap = kept(result&.output, MAX_OUTPUT_BYTES, "output_cut")
          state, state_gap = kept(result&.state, MAX_STATE_BYTES, "state_cut")
          [output, state, [output_gap, state_gap].compact]
        end

        # Which trial, and how it ended: the last attempt's outcome.
        def head(trial, segment, split, attempts)
          outcome = attempts.last.outcome
          { "format" => FORMAT, "format_version" => 1, "eval_run_id" => trial.eval_run_id,
            "trial_id" => trial.trial_id, "trial_revision" => 1, "segment" => segment, "sample_id" => trial.sample.id,
            "trial_index" => trial.trial_index, "candidate_id" => nil, "split" => split,
            "outcome" => outcome.outcome.to_s, "reason" => outcome.reason, **times(attempts) }
        end

        def times(attempts)
          first = attempts.first
          last = attempts.last
          duration = ((last.started - first.started) * 1000).round + last.duration_ms
          { "started_at" => Store::Clock.timestamp(first.started_at),
            "ended_at" => Store::Clock.timestamp(first.started_at + Rational(duration, 1000)),
            "duration_ms" => duration, "latency_ms" => last.duration_ms }
        end

        def attempt(attempt, number)
          { "n" => number, "outcome" => attempt.outcome.outcome.to_s, "reason" => attempt.outcome.reason,
            "started_at" => Store::Clock.timestamp(attempt.started_at), "duration_ms" => attempt.duration_ms,
            "cost_nanos" => attempt.usage["cost_nanos"], "error" => error(attempt) }
        end

        def subject(result)
          { "final_state" => result&.final_state, "ended" => result&.ended&.to_s,
            "waiting" => result&.waiting&.to_s }
        end

        def usage(attempts)
          attempts.each_with_object(Spend.new) { |attempt, spend| spend.add_usage(attempt.usage) }.usage
        end

        # [the JSON form kept, or nil; the gap when it could not be kept].
        def kept(value, max_bytes, gap)
          return [nil, nil] if value.nil?
          return [nil, gap] if CanonicalJSON.generate(value).bytesize > max_bytes

          [JSONValue.normalized(value), nil]
        rescue CanonicalJSON::Error
          [nil, gap]
        end

        def error(attempt)
          error = attempt.error
          return if error.nil?

          code = attempt.outcome.reason&.fetch("code")
          message = FIXED.key?(code) ? AttemptObservation::FIXED_MESSAGES.fetch(FIXED[code]) : error.message
          { "class" => DiagnosticText.error_class_name(error),
            "family" => Smith::Workflow::FailureRecord.capture({ error: })[:error_family],
            "message" => DiagnosticText.capture(message.to_s, max_bytes: 1_024) }
        end
      end
    end
  end
end
