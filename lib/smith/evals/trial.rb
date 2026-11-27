# frozen_string_literal: true

require_relative "../diagnostic_text"
require_relative "../json_value"

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
    # cost_nanos:, cost_complete:}); and its duration. Frozen. `from_line`
    # builds one again from a stored trial line (the tuner reads feedback
    # from it): its state's keys Symbols, as the context's are, its output
    # and usage as the line keeps them (the JSON form; every attempt's).
    Trial = Data.define(:id, :index, :sample_id, :outcome, :state, :output, :final_state, :failure, :steps,
                        :tool_calls, :usage, :duration_ms) do
      def self.for(spec, result, outcome, recorder)
        steps = recorder.steps
        new(id: spec.trial_id, index: spec.trial_index, sample_id: spec.sample.id, outcome: outcome.outcome,
            state: result.state || {}.freeze, output: result.output, final_state: result.final_state&.to_sym,
            failure: failure(result, outcome), steps:, tool_calls: tool_calls(steps), usage: usage(recorder),
            duration_ms: result.duration_ms)
      end

      def self.from_line(line)
        outcome = scored_as(line["outcome"])
        new(id: line["trial_id"], index: line["trial_index"], sample_id: line["sample_id"], outcome:,
            failure: stored_failure(line, outcome), usage: spent(line["usage"]), duration_ms: line["latency_ms"],
            **kept(line))
      end

      # The outcome a scorer was given, from the line's.
      def self.scored_as(outcome)
        case outcome
        when "scored", "unscored" then :answered
        when "subject_failed", "limit_hit" then outcome.to_sym
        else raise ArgumentError, "a trial that ended #{outcome} was not scored"
        end
      end

      def self.kept(line)
        steps = line["steps"]
        { state: JSONValue.symbolized(line["state"] || {}), output: line["output"], steps:,
          final_state: line.dig("subject", "final_state")&.to_sym, tool_calls: tool_calls(steps) }
      end

      def self.stored_failure(line, outcome)
        error = line["error"]
        return unless error && outcome != :answered

        { class: error["class"], family: error["family"], message: error["message"],
          reason: line.dig("reason", "code") }.freeze
      end

      def self.usage(recorder) = spent(recorder.usage)

      def self.spent(usage)
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

      private_class_method :usage, :spent, :failure, :tool_calls, :step_calls, :scored_as, :kept, :stored_failure
    end
  end
end
