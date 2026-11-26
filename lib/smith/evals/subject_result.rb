# frozen_string_literal: true

module Smith
  module Evals
    # Experimental; frozen with slice 1a.4. What a driver returns for one
    # trial attempt (slice-1a design, 5.2), all a scorer may read, taken
    # inside the trial's isolation:
    #
    # ended: :terminal (a state with no way on), :until (the suite's named
    # state), :waiting (a wait the driver cannot deliver) or :raised (the run
    # raised); final_state: the state's name; failed: whether it ended in its
    # failed state; output: the workflow's output; state: the suite's keep
    # keys from the run's context (symbol keys; nil when it left none);
    # error: the raised error, or the failed step's error; waiting: the wait
    # kind (:await, :delay, :children, :batch) when it waits; usage_entries:
    # the run's (Workflow#usage_entries, nested workflows' rolled in);
    # child_runs: how many child-run steps had their children run apart from
    # the trial (Smith::Launchers::Inline runs them with attribution cleared,
    # so their attempts are not recorded); duration_ms: how long the driver
    # ran it. A host driver builds one with `from_workflow` from a run it
    # drove or restored, `child_runs` 0 for children it drives on the trial's
    # own thread (they are recorded). Frozen.
    SubjectResult = Data.define(:ended, :final_state, :failed, :output, :state, :error, :waiting, :usage_entries,
                                :child_runs, :duration_ms) do
      def self.from_workflow(workflow, run_result, keep:, until: nil, child_runs: 0, duration_ms: nil)
        until_state = binding.local_variable_get(:until)
        failed = workflow.failed?
        new(ended: ended(workflow, until_state), final_state: workflow.state&.to_s, failed:,
            output: run_result&.output, state: kept(run_result&.context, keep), waiting: waiting(workflow),
            error: (run_result&.last_error if failed), usage_entries: workflow.usage_entries, child_runs:,
            duration_ms:)
      end

      # `workflow` is nil when building it raised; its context is read from
      # its saved form, as far as the run got.
      def self.raised(workflow, error, keep:, child_runs: 0, duration_ms: nil)
        context = begin
          workflow&.to_state&.dig(:context)
        rescue StandardError
          nil
        end
        new(ended: :raised, final_state: workflow&.state&.to_s, failed: false, output: nil, state: kept(context, keep),
            error:, waiting: nil, usage_entries: workflow ? workflow.usage_entries : [].freeze, child_runs:,
            duration_ms:)
      end

      def self.ended(workflow, until_state)
        return :until if until_state && workflow.state.to_s == until_state.to_s
        return :waiting if workflow.waiting?

        :terminal
      end

      def self.waiting(workflow) = workflow.awaiting&.kind&.to_sym

      def self.kept(context, keep)
        return unless context.is_a?(Hash)

        kept = Array(keep).each_with_object({}) do |key, values|
          name = key.to_sym
          values[name] = context[name] if context.key?(name)
        end
        kept.empty? ? nil : kept.freeze
      end

      private_class_method :ended, :waiting, :kept
    end
  end
end
