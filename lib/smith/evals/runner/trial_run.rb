# frozen_string_literal: true

require_relative "../configuration"
require_relative "../outcomes"
require_relative "../recorder"
require_relative "../recording"
require_relative "../subject_result"
require_relative "../trial"
require_relative "../trial_spec"
require_relative "../record/trial_line"

module Smith
  module Evals
    class Runner
      # Internal. One attempt of one trial (slice-1a design, 5.5): a fresh
      # recorder attached, under the recording bounds the run's header names
      # (design 5.4: the values in force, so a resume keeps them whatever the
      # configuration says now), the driver's isolation around the driver's
      # run, then, outside it, the outcome read and the scorers run on what
      # the trial keeps. A failure of the driver's own (or a result that is
      # no SubjectResult) is the driver's (driver_error, or scope_conflict).
      # A trial is final unless it ended in a retried error with retries
      # left.
      class TrialRun
        # The attempts so far, and what the last left: its trial spec,
        # subject result, recorder and scores.
        Tried = Data.define(:attempts, :spec, :result, :recorder, :scores)
        # The outcomes a trial is scored in (design 6.1).
        SCORED = %i[answered subject_failed limit_hit].freeze
        # A failed subject's score when the scorer is not run.
        OUTCOME_RULE = { "status" => "scored", "source" => "outcome_rule", "scorer_version" => nil, "passed" => nil,
                         "value" => 0, "label" => nil, "explanation" => "the subject failed, which counts as a fail",
                         "metadata" => nil, "reason" => nil }.freeze

        # record: the run's Record.
        def initialize(plan, record)
          @plan = plan
          @eval_run_id = record.eval_run_id
          @recording = Configuration.recording(record.header.fetch("recording"))
        end

        # The trial after one more attempt.
        def attempt(item)
          spec = spec_for(item)
          recorder = Recorder.new(spec.trial_id, recording: @recording)
          result, done = run_once(spec, recorder)
          scores, done = scored(spec, result, done, recorder)
          Tried.new(attempts: [*item.tried&.attempts, done], spec:, result:, recorder:, scores:)
        end

        # Whether a trial goes back for another attempt.
        def retry?(tried)
          outcome = tried.attempts.last.outcome
          outcome.outcome == :error && outcome.retryable && tried.attempts.size <= @plan.error_retries
        end

        # Its trial line.
        def line(tried, segment)
          Record::TrialLine.build(tried.spec, segment:, split: @plan.split, attempts: tried.attempts,
                                              result: tried.result, scores: tried.scores, recorder: tried.recorder)
        end

        private

        def spec_for(item)
          TrialSpec.for(eval_run_id: @eval_run_id, scope: @plan.scope, sample: item.sample, trial_index: item.index,
                        subject: @plan.subject, attempt: (item.tried&.attempts&.size || 0) + 1)
        end

        # The subject's result, and the attempt as it ended, timed.
        def run_once(spec, recorder)
          started_at = Time.now
          started = clock
          result, outcome, error = driven(spec, recorder)
          [result, Record::TrialLine::Attempt.new(outcome:, started_at:, started:, error:, usage: recorder.usage,
                                                  duration_ms: ((clock - started) * 1000).round)]
        end

        def driven(spec, recorder)
          result = nil
          begin
            Recording.attach(recorder) do
              @plan.driver.around_trial(spec) { result = @plan.driver.run(spec, spec.context) }
            end
            raise TypeError, "the driver gave #{result.class}, not a SubjectResult" unless result.is_a?(SubjectResult)
          rescue StandardError => e
            return [nil, Outcomes.driver_failed(e), e]
          end
          outcome = Outcomes.classify(result, steps: recorder.steps, infrastructure_errors: @plan.infrastructure_errors)
          [result, outcome, result.error]
        end

        # The scores, by scorer name as the line keeps them, and the attempt
        # with its outcome after scoring. An answered trial is scored (and is
        # unscored when a scorer could not decide); a failed subject counts
        # as a fail without running a scorer unless it declared
        # on_subject_failure :score; a subject that ran out of its limit is
        # scored on what it had done.
        def scored(spec, result, attempt, recorder)
          outcome = attempt.outcome
          return [{}, attempt] unless SCORED.include?(outcome.outcome)

          scores = scores(spec, Trial.for(spec, result, outcome, recorder), outcome)
          outcome = Outcomes.scored(scores.transform_keys(&:name).compact) if outcome.outcome == :answered
          [scores.to_h { |entry, score| [entry.name, kept(entry, score)] }, attempt.with(outcome:)]
        end

        def scores(spec, trial, outcome) = @plan.scorers.to_h { [_1, score(_1, spec.sample, trial, outcome)] }

        # nil for the outcome rule's fail.
        def score(entry, sample, trial, outcome)
          entry.scorer.evaluate(sample, trial) unless outcome.outcome == :subject_failed &&
                                                      entry.on_subject_failure == :fail
        end

        # A score as the line keeps it.
        def kept(entry, score)
          return OUTCOME_RULE.merge("scorer_version" => entry.version, "passed" => passed(entry)) if score.nil?

          form = score.to_h
          { "status" => form["status"], "source" => "scorer", "scorer_version" => entry.version,
            **form.except("status") }
        end

        def passed(entry) = entry.scale == :binary ? false : nil

        def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
