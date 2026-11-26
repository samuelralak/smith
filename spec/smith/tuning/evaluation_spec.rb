# frozen_string_literal: true

require "smith/tuning"

# The loop's seam to the runner (slice 5a design, section 2): its two
# calls and their answers. The specs' stub keeps the contract, as Smith's
# own implementation will.
RSpec.describe Smith::Tuning::Evaluation do
  let(:candidate) do
    Smith::Tuning::Candidate.seed(TuningRecords.prompts, components: nil, tuning_run_id: TuningRecords.run_id(1))
  end
  let(:component) { "answer.predict" }
  let(:train_ids) { TuningRecords.train_ids }
  let(:validation_ids) { TuningRecords.validation_ids }

  describe "the stub" do
    let(:trials) do
      TuningTrialsStub.new(score: ->(_candidate, id) { id.end_with?("1") ? 1.0 : 0.0 },
                           feedback: ->(_candidate, id, part) { "#{part} missed #{id}" })
    end

    let(:capped) { TuningTrialsStub.new(score: ->(*) { 1.0 }, admit: 0) }

    it_behaves_like "a tuning trials seam"

    it "runs what its budget admits, reflections included, and says the pass stopped at the cap" do
      budgeted = TuningTrialsStub.new(score: ->(*) { 1.0 }, admit: 3)
      budgeted.reflect("m", trial_id: "tr_#{"0" * 32}")
      pass = budgeted.evaluate(candidate, sample_ids: train_ids.first(3), kind: :tuning_minibatch, key: "k")

      expect([pass.samples.keys, pass.metric_calls, pass.provider_calls, pass.complete, pass.stop])
        .to eq([train_ids.first(2), 2, 2, false, :cap_reached])
      expect(budgeted.reflect("m", trial_id: "tr_#{"1" * 32}").stop).to eq(:cap_reached)
    end

    it "gives a model's failure as a failure with no stop, so only its iteration ends" do
      failing = TuningTrialsStub.new(score: ->(*) { 1.0 }, reply: ->(_message) { raise IOError, "the reply broke" })
      call = failing.reflect("m", trial_id: "tr_#{"0" * 32}")

      expect([call.output, call.stop, call.failure])
        .to eq([nil, nil, { "kind" => "aborted", "error_class" => "IOError", "message" => "the reply broke" }])
    end
  end

  describe Smith::Tuning::Evaluation::Pass do
    def pass(scores)
      samples = scores.transform_values { Smith::Tuning::Evaluation::Sample.new(score: _1, feedback: nil, steps: nil) }
      described_class.new(eval_run_id: "er_#{"0" * 32}", samples:, metric_calls: samples.size,
                          provider_calls: samples.size, cost_nanos: 0, cost_complete: true, complete: true, stop: nil)
    end

    it "gives its scores by sample and their mean, none for a pass that ran no sample" do
      expect(pass("a" => 1.0, "b" => 0.0, "c" => 0.5).then { [_1.scores, _1.mean] })
        .to eq([{ "a" => 1.0, "b" => 0.0, "c" => 0.5 }, 0.5])
      expect(pass({}).mean).to be_nil
    end
  end

  it "takes as a seam only an object answering both calls" do
    expect(described_class.seam?(Object.new)).to be(false)
    expect(described_class.seam?(Struct.new(:evaluate).new)).to be(false)
  end
end
