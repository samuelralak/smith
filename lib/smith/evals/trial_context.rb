# frozen_string_literal: true

module Smith
  module Evals
    # Experimental. What a driver is handed for one trial and passes to
    # Smith::Evals.under (slice-1a design, 5.3): the trial and eval run ids,
    # the scope, the sample id, the trial index and the candidate id (nil
    # until slice 5a). `to_h` is its JSON form, which slice 3a saves with
    # each workflow run under a trial and gives child runs in their input
    # (adding candidate_ref, pins, ledger_scope, recorder_sink and
    # cancel_check). Frozen.
    TrialContext = Data.define(:trial_id, :eval_run_id, :scope, :sample_id, :trial_index, :candidate_id) do
      def to_h
        form = { "format" => "smith.evals.trial_context", "format_version" => 1, "trial_id" => trial_id,
                 "eval_run_id" => eval_run_id, "scope" => scope.to_h, "sample_id" => sample_id,
                 "trial_index" => trial_index }
        form["candidate_id"] = candidate_id unless candidate_id.nil?
        form
      end
    end
  end
end
