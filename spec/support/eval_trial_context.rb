# frozen_string_literal: true

# One eval trial on the local server (or on request-aware stubs): its spec
# and context, a recorder attached for it, and the subject run inside
# Smith::Evals.under, as the runner does. Requests a stub does not answer
# go to the local server, never further.
RSpec.shared_context "with an eval trial" do
  include_context "with a recording budget ledger"

  let(:eval_run_id) { "er_#{"0" * 31}1" }
  let(:eval_scope) { Smith::Scope.build(tenant: "ten_1") }
  let(:sample) { Smith::Evals::Sample.new({ "id" => "t-1", "input" => { "text" => "My parcel never came." } }, split: :dev) }
  let(:trial_spec) do
    Smith::Evals::TrialSpec.for(eval_run_id:, scope: eval_scope, sample:, trial_index: 0, subject: nil)
  end
  let(:trial_context) { trial_spec.context }

  # The step records of what the block ran under the trial, the recorder
  # attached for its duration.
  def recorded(recorder = Smith::Evals::Recorder.new(trial_spec.trial_id), &)
    Smith::Evals::Recording.attach(recorder) { Smith::Evals.under(trial_context, &) }
    recorder
  end

  def step_errors(step, strict:)
    EvalsSchema.errors(step, schema: "trial", strict:, pointer: "#/$defs/step")
  end

  # Each record valid against the trial schema's step, as published and
  # with unknown fields refused.
  def expect_valid_steps(steps)
    steps.each do |step|
      expect([step_errors(step, strict: false), step_errors(step, strict: true)]).to eq([[], []]), step.inspect
    end
  end
end
