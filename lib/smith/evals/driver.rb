# frozen_string_literal: true

require "securerandom"
require_relative "../attempt_observation"
require_relative "recording"

module Smith
  module Evals
    # Experimental; the in-process form is frozen with slice 1a.4. How one
    # trial of a subject runs (slice-1a design, 4.9): `run(trial, context)`
    # runs it inside Smith::Evals.under(context) and returns a
    # SubjectResult; anything it raises itself is the driver's own failure
    # (driver_error, or scope_conflict for a ScopeConflict). `around_trial`
    # wraps every attempt of a trial in the driver's isolation (a rolled-back
    # transaction, say); the runner never runs more than `max_concurrency`
    # trials at once. Slice 3a adds the :across_processes form (5.3).
    class Driver
      # A step's settings when the driver gives none; how many of its
      # messages were sent when it does not say: all but the replies at the
      # end.
      UNSENT = { temperature: nil, max_output_tokens: nil, thinking: nil }.freeze
      SENT = ->(messages) { messages.length - messages.reverse.take_while { _1["role"] == "assistant" }.length }
      private_constant :UNSENT, :SENT

      def self.form = :in_process

      def max_concurrency = 1

      # :around_trial when a subclass gives its own around_trial.
      def isolation = self.class.instance_method(:around_trial).owner == Driver ? :none : :around_trial

      def around_trial(_trial) = yield

      # How the runner waits before a trial's retry after an error: :sleep,
      # a backoff of min(30, 2**attempt) seconds, or :immediate, none.
      def retry_waits = :sleep

      # The seconds to wait before another attempt after `attempts`
      # attempts, by retry_waits: the runner's before a trial's retry, a
      # tuning run's before a reflection's.
      def backoff(attempts) = retry_waits == :immediate ? 0 : [30, 2**attempts].min

      # The components a tuning run may rewrite in `subject` (the suite's
      # Smith::Evals::Subject), each id with its base text, as
      # {"answer.predict" => "Answer the question."}: by default the named
      # prompts of a workflow subject (Smith::Prompts.components), and none
      # of any other. A host driver that runs a program of its own declares
      # them here, and sends a trial's `candidate.texts` in their place;
      # versions are Smith::Prompt's digest of each text.
      def components(subject)
        workflow = subject.workflow
        return {} unless workflow.is_a?(Class) && workflow < Smith::Workflow

        Prompts.components(workflow).transform_values(&:text)
      end

      def run(_trial, _context)
        raise NotImplementedError, "#{self.class} defines run(trial, context), returning a SubjectResult"
      end

      # Records one model call a host driver made for `trial` (the
      # TrialSpec `run` was given), from inside `run`, as Smith's own driver
      # records its calls: a step record priced from its tokens, bounded,
      # in the trial's line, and read by a tuning run's check that each
      # component its candidate changed was sent at the candidate's version.
      # tokens: {input:, output:, cache_read:, cache_write:, thinking:};
      # components: [{id:, version:}], each named prompt the call sent and
      # the version of the text it sent (Smith::Prompt#version); messages:
      # the trial schema's ({"role" => "system", "text" => ...}), the first
      # `sent` of them sent (by default all but the replies at the end);
      # outcome: :completed, :failed (the provider refused it) or :aborted,
      # failure: {kind:, error_class:, message:}; started: the monotonic
      # clock when the call started; settings: what it was sent with,
      # {temperature:, max_output_tokens:, thinking: {effort:, budget:}}
      # (each nil when not sent; Symbol or String keys); agent: the part of the program that made
      # it (the driver's class name when not given). Tool calls are not
      # recorded. Outside a trial's run it records nothing. Returns nil.
      def record_step(trial, model:, provider:, tokens: nil, components: nil, messages: [], sent: nil,
                      outcome: :completed, failure: nil, started: nil, duration_ms: nil, stop_reason: nil,
                      settings: nil, agent: nil)
        messages = messages.map { _1.transform_keys(&:to_s) }
        step = AttemptObservation::Attempt.new(
          trial: trial.trial_id, agent: (agent || self.class.name).to_s, components:, attempt_id: SecureRandom.uuid,
          attempt_index: 0, outcome: outcome.to_sym, failure:, model:, provider:, mode: :sync, memo: false,
          duration_ms:, tokens:, responses: tokens ? [{ tokens:, mode: :sync }] : [], stop_reason:, messages:,
          sent_count: sent || SENT.call(messages), tool_call_names: [], position: {}, started:,
          settings: sent_settings(settings)
        )
        Recording.attempt_finished(step)
        nil
      end

      private

      # The settings a driver gave, read by Symbol keys wherever they came
      # from (a parsed JSON file has String keys), thinking's included.
      def sent_settings(given)
        given = (given || {}).transform_keys(&:to_sym)
        thinking = given[:thinking]
        given[:thinking] = thinking.transform_keys(&:to_sym) if thinking.is_a?(Hash)
        UNSENT.merge(given)
      end
    end
  end
end
