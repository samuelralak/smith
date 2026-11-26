# frozen_string_literal: true

require_relative "../diagnostic_text"

module Smith
  module Evals
    # Experimental. One trial as a scorer reads it (slice-1a design, 4.8),
    # built outside the trial's isolation from what the driver returned and
    # the recorder kept, so a stored record can be scored again from its
    # line: its id, index and sample id; its outcome before scoring
    # (:answered, :subject_failed or :limit_hit); the kept state (symbol
    # keys; {} when none) and output; its final state; its failure (nil, or
    # {class:, family:, message:, reason:} for a failed subject, the message
    # bounded); its step records; the tool calls in them ({name:,
    # arguments:}, arguments nil with content off); its usage ({tokens:,
    # cost_nanos:, cost_complete:}); and its duration. Frozen.
    Trial = Data.define(:id, :index, :sample_id, :outcome, :state, :output, :final_state, :failure, :steps,
                        :tool_calls, :usage, :duration_ms) do
      def self.for(spec, result, outcome, recorder)
        steps = recorder.steps
        new(id: spec.trial_id, index: spec.trial_index, sample_id: spec.sample.id, outcome: outcome.outcome,
            state: result.state || {}.freeze, output: result.output, final_state: result.final_state&.to_sym,
            failure: failure(result, outcome), steps:, tool_calls: tool_calls(steps), usage: usage(recorder),
            duration_ms: result.duration_ms)
      end

      def self.usage(recorder)
        usage = recorder.usage
        { tokens: usage["tokens"], cost_nanos: usage["cost_nanos"], cost_complete: usage["cost_complete"] }.freeze
      end

      def self.failure(result, outcome)
        return unless result.error && %i[subject_failed limit_hit].include?(outcome.outcome)

        { class: DiagnosticText.error_class_name(result.error), family: outcome.family,
          message: DiagnosticText.capture(result.error.message, max_bytes: 1_024),
          reason: outcome.reason["code"] }.freeze
      end

      # A step's calls from the messages it added, or by name alone when its
      # messages were not kept whole.
      def self.tool_calls(steps) = steps.flat_map { step_calls(_1) }.freeze

      def self.step_calls(step)
        added = step["messages"]&.drop(step["sent_count"]) if step["cut"]["elided_messages"].zero?
        return step["tool_call_names"].map { { name: _1, arguments: nil }.freeze } unless added

        added.flat_map { Array(_1["tool_calls"]) }.map { { name: _1["name"], arguments: _1["arguments"] }.freeze }
      end

      private_class_method :usage, :failure, :tool_calls, :step_calls
    end
  end
end
