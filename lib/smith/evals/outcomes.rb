# frozen_string_literal: true

require_relative "../diagnostic_text"
require_relative "outcomes/error_reading"

module Smith
  module Evals
    # Experimental. From how a trial's subject ended to its outcome
    # (slice-1a design, 6.1 to 6.3): `classify` reads a SubjectResult (with
    # the trial's step records, whose failure kinds decide the provider rows)
    # before scoring, `scored` reads an answered trial's scores, and
    # `driver_failed` reads what a driver itself raised. Each gives an
    # Outcome: the outcome (:answered, to be scored, :scored, :unscored,
    # :subject_failed, :limit_hit or :error), its reason (the trial line's
    # {"code", "by", "detail"}, the detail a class name or Smith's own words,
    # never an error's message; nil for :answered and :scored), whether an
    # error is retried and whether it stops the run, and the subject error's
    # family as Smith records it. Not run (a cancel, the cap, a stopped
    # run) is the runner's to say (slice 1a.5, the cap 1b).
    module Outcomes
      Outcome = Data.define(:outcome, :reason, :retryable, :stops_run, :family)

      ANSWERED = Outcome.new(outcome: :answered, reason: nil, retryable: false, stops_run: false, family: nil)
      SCORED = Outcome.new(outcome: :scored, reason: nil, retryable: false, stops_run: false, family: nil)
      private_constant :ANSWERED, :SCORED, :ErrorReading, :Readings

      class << self
        # `infrastructure_errors`: the suite's own (trials.infrastructure_errors).
        def classify(result, steps:, infrastructure_errors: [])
          case result.ended
          when :until then ANSWERED
          when :waiting then waited(result.waiting)
          when :raised then by_error(result.error, steps, infrastructure_errors)
          else ended(result, steps, infrastructure_errors)
          end
        end

        # What a driver's own `run` raised: a scope conflict stops the run;
        # anything else is retried.
        def driver_failed(error)
          return outcome(:error, "scope_conflict", "eval_run", detail(error.message), stops: true) if
            error.is_a?(ScopeConflict)

          outcome(:error, "driver_error", "infrastructure", "the driver raised #{class_name(error)}", retryable: true)
        end

        # An answered trial's scores by scorer name, in the suite's order:
        # unscored when any could not decide, with the first such reason.
        def scored(scores)
          undecided = scores.each_value.find { _1.status == :unscored }
          return SCORED unless undecided

          Outcome.new(outcome: :unscored, reason: undecided.reason, retryable: false, stops_run: false, family: nil)
        end

        private

        def ended(result, steps, infrastructure_errors)
          return ANSWERED unless result.failed
          return by_error(result.error, steps, infrastructure_errors) if result.error

          outcome(:subject_failed, "failed_state", "subject", "the run ended in its failed state with no error")
        end

        def waited(kind)
          outcome(:error, "subject_waited", "infrastructure",
                  "the run waits (#{kind}), which the driver cannot deliver")
        end

        def by_error(error, steps, infrastructure_errors)
          kind, code, by, retryable, stops, decided = ErrorReading.new(steps:, infrastructure_errors:).call(error)
          Outcome.new(outcome: kind, reason: reason(code, by, class_name(decided)), retryable:, stops_run: stops,
                      family: ErrorReading.family(error))
        end

        def outcome(kind, code, by, text, retryable: false, stops: false)
          Outcome.new(outcome: kind, reason: reason(code, by, text), retryable:, stops_run: stops, family: nil)
        end

        def reason(code, by, text) = { "code" => code, "by" => by, "detail" => detail(text) }.freeze

        def detail(text) = DiagnosticText.capture(text.to_s, max_bytes: 1_024)

        def class_name(error) = DiagnosticText.error_class_name(error)
      end
    end
  end
end
