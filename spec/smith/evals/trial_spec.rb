# frozen_string_literal: true

require "smith/evals"
require "smith/testing"

# A trial as a scorer reads it, built again from its stored line (slice 5a
# design, section 2: the tuner asks a scorer's feedback on a stored trial).
RSpec.describe Smith::Evals::Trial do
  include_context "with an eval run suite"

  it "reads a stored line back as the trial its scorer was given, the subject's own time aside" do
    seen = {}
    lock = Mutex.new
    klass = suite(trials: 1)
    klass.settings[:scorers].clear
    klass.scorer(:category, version: 1, on_subject_failure: :score) do |sample, trial|
      lock.synchronize { seen[sample.id] = trial }
      Smith::Evals::Score.match(trial.state.dig(:triage, :category), sample.expected[:category])
    end
    lines = run_suite(klass).record.each_trial.to_a

    expect(lines.map { _1["outcome"] }.tally).to eq("scored" => 11, "subject_failed" => 1)
    lines.each do |line|
      expect(described_class.from_line(line).to_h.except(:duration_ms))
        .to eq(seen.fetch(line["sample_id"]).to_h.except(:duration_ms)), line["sample_id"]
    end
  end

  it "refuses a line whose trial was never scored" do
    line = { "outcome" => "error", "trial_id" => "tr_#{"0" * 32}" }

    expect { described_class.from_line(line) }.to raise_error(ArgumentError, "a trial that ended error was not scored")
  end
end
