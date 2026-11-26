# frozen_string_literal: true

# The tuning loop's seam to the runner (Smith::Tuning::Evaluation), as an
# example group every implementation passes: the specs' stub now, Smith's
# own on Smith::Evals.run and the in-process driver next. The including
# group defines `trials` (the seam, its subject sending `candidate`'s
# components), `capped` (the same seam with its cap reached, so it admits
# no further call), `candidate`, `component` (one of its components),
# `train_ids` and `validation_ids` (of the suite's selection).
RSpec.shared_examples "a tuning trials seam" do
  let(:run_id) { candidate.tuning_run_id }

  it "answers the seam" do
    expect(Smith::Tuning::Evaluation.seam?(trials)).to be(true)
  end

  it "runs a validation pass: a score from 0 to 1 a sample, no feedback or steps, a metric call each" do
    pass = trials.evaluate(candidate, sample_ids: validation_ids, kind: :tuning_validation, key: "#{run_id}/0/seed")

    expect(pass).to be_a(Smith::Tuning::Evaluation::Pass)
    expect(pass.eval_run_id).to match(/\Aer_[0-9a-f]{32}\z/)
    expect(pass.samples.keys).to eq(validation_ids)
    expect(pass.samples.values.map(&:score)).to all(be_between(0, 1))
    expect(pass.samples.values.map { [_1.feedback, _1.steps] }.uniq).to eq([[nil, nil]])
    expect([pass.metric_calls, pass.complete, pass.stop]).to eq([validation_ids.size, true, nil])
    expect([pass.cost_nanos, pass.provider_calls]).to all(be_a(Integer).and(be >= 0))
  end

  it "runs a minibatch with each sample's feedback and step records, the component's carrying its version" do
    ids = train_ids.first(3)
    pass = trials.evaluate(candidate, sample_ids: ids, kind: :tuning_minibatch, key: "#{run_id}/1/parent", component:)

    expect(pass.samples.keys).to eq(ids)
    pass.samples.each_value do |sample|
      expect(sample.feedback).to be_nil.or(be_a(String))
      own = sample.steps.filter_map { |step| step["components"]&.find { _1["id"] == component } }
      expect(own).not_to be_empty
      expect(own.map { _1["version"] }.uniq).to eq([candidate.versions[component]])
    end
  end

  it "gives the same pass again for the same key" do
    first = trials.evaluate(candidate, sample_ids: validation_ids, kind: :tuning_validation, key: "#{run_id}/0/seed")
    again = trials.evaluate(candidate, sample_ids: validation_ids, kind: :tuning_validation, key: "#{run_id}/0/seed")

    expect(again).to eq(first)
  end

  # The real runner refuses a known key whose plan differs (ResumeMismatch),
  # so a restore that picks the wrong parent or minibatch is never handed
  # the first one's pass.
  it "refuses the same key for another candidate or other samples" do
    key = "#{run_id}/1/parent"
    other = candidate.child(component, "#{candidate.texts[component]} Be brief.", iteration: 1, parent: 0)
    trials.evaluate(candidate, sample_ids: train_ids.first(3), kind: :tuning_minibatch, key:, component:)

    expect { trials.evaluate(other, sample_ids: train_ids.first(3), kind: :tuning_minibatch, key:, component:) }
      .to raise_error(Smith::Evals::ResumeMismatch)
    expect { trials.evaluate(candidate, sample_ids: train_ids.last(3), kind: :tuning_minibatch, key:, component:) }
      .to raise_error(Smith::Evals::ResumeMismatch)
  end

  # A ledger refusal ends the tuning run (stopped_at_limit); a model's
  # failure only ends its iteration.
  it "says when the cap stops a pass or a reflection, and the record keeps it" do
    pass = capped.evaluate(candidate, sample_ids: validation_ids, kind: :tuning_validation, key: "#{run_id}/0/seed")
    trial_id = Smith::Evals::Identity.reflection_trial_id(tuning_run_id: run_id, iteration: 1)
    call = capped.reflect("The step's component: #{component}", trial_id:)
    line = Smith::Tuning::Record.reflection(tuning_run_id: run_id, iteration: 1, call:)

    expect([pass.complete, pass.stop]).to eq([false, :cap_reached])
    expect([call.output, call.stop, call.failure.nil?]).to eq([nil, :cap_reached, false])
    expect(line.values_at("output", "stop")).to eq([nil, "cap_reached"])
    %i[open strict].each do |mode|
      expect(EvalsSchema.errors(line, schema: "tuning-line", strict: mode == :strict)).to eq([])
    end
  end

  it "makes a reflection call as a trial with the given id, which its record line holds" do
    trial_id = Smith::Evals::Identity.reflection_trial_id(tuning_run_id: run_id, iteration: 1)
    call = trials.reflect("The step's component: #{component}", trial_id:)
    line = Smith::Tuning::Record.reflection(tuning_run_id: run_id, iteration: 1, call:)

    expect(call).to be_a(Smith::Tuning::Reflection::Call)
    expect(call.trial_id).to eq(trial_id)
    expect([call.output, call.failure].compact.size).to eq(1)
    expect(call.stop).to be_nil
    %i[open strict].each do |mode|
      expect(EvalsSchema.errors(line, schema: "tuning-line", strict: mode == :strict)).to eq([])
    end
  end
end
