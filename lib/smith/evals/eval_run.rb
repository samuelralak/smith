# frozen_string_literal: true

require_relative "reducers"
require_relative "statistics"

module Smith
  module Evals
    # Experimental. What Smith::Evals.run returns (slice-1a design, 4.6): the
    # run's id, its record and its summary as the store keeps them.
    #
    #   run.status                           # => :succeeded, :failed, :cancelled or :incomplete
    #   run.result(:category)                # => the headline Statistics::Estimate
    #   run.result(:priority, reducer: :mean)
    #
    # A result is read back from the summary, so a run returned for a known
    # idempotency key reads as the run that wrote it. Frozen.
    class EvalRun
      attr_reader :record, :summary

      def initialize(record)
        @record = record
        @summary = record.summary
        freeze
      end

      def eval_run_id = record.eval_run_id

      # nil while the run has no summary.
      def status = summary&.fetch("status")&.to_sym

      # The scorer's estimate under `reducer`, by default its headline one.
      def result(scorer, reducer: nil)
        fields = entry(scorer.to_s, reducer && Reducers.name_of(reducer)).fetch("estimate").except("schema", "type")
        Statistics::Estimate.new(**fields.to_h { |key, value| [key == "method" ? :method_name : key.to_sym, value] })
      end

      private

      def entry(scorer, reducer)
        found = Array(summary&.fetch("results")).find do |result|
          result["scorer"] == scorer && (reducer ? result["reducer"] == reducer : result["headline"])
        end
        found or raise ArgumentError,
                       "eval run #{eval_run_id} has no result for #{[scorer, reducer].compact.join(" by ")}"
      end
    end
  end
end
