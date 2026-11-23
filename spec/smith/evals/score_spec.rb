# frozen_string_literal: true

require "smith/evals"

# Scores (slice-1a design 4.3): what a scorer returns for one trial.
RSpec.describe Smith::Evals::Score do
  def fields(score) = [score.status, score.passed, score.value, score.scale]

  it "passes and fails on the binary scale, with an optional explanation, label and metadata" do
    pass = described_class.pass("looks right", label: "billing", metadata: { check: "manual", n: 1 })

    expect(fields(pass)).to eq([:scored, true, 1.0, :binary])
    expect([pass.explanation, pass.label, pass.metadata, pass.reason])
      .to eq(["looks right", "billing", { "check" => "manual", "n" => 1 }, nil])
    expect(fields(described_class.fail)).to eq([:scored, false, 0.0, :binary])
    expect(pass).to be_frozen
    expect(pass.metadata).to be_frozen
  end

  it "matches values equal after canonical JSON, explaining as the published examples do" do
    expect(described_class.match(:billing, "billing").explanation).to eq("matched billing")
    expect(described_class.match({ a: 1.0, b: [2] }, { "b" => [2], "a" => 1 }).passed).to be(true)
    expect(described_class.match("shipping", "billing"))
      .to have_attributes(passed: false, explanation: "expected billing, got shipping")
    expect(described_class.match(nil, "billing").explanation).to eq("expected billing, got nothing")
    expect(described_class.match({ "a" => 1 }, { "a" => 2 }).explanation).to eq(%(expected {"a":2}, got {"a":1}))
    expect(described_class.match("x", "x", label: "exact").label).to eq("exact")
  end

  it "keeps a continuous value from 0 to 1, with no pass or fail" do
    expect(fields(described_class.value(0.75))).to eq([:scored, nil, 0.75, :continuous])
    expect(described_class.value(1).value).to eq(1.0)
  end

  it "records a grader that could not decide as unscored, grader_undecided" do
    score = described_class.unscored("the answer has no priority")

    expect(fields(score)).to eq([:unscored, nil, nil, nil])
    expect(score.reason).to eq("code" => "grader_undecided", "by" => "grader", "detail" => "the answer has no priority")
  end

  it "makes an invalid score unscored, score_invalid, never a pass or a fail" do
    invalid = [
      described_class.value(1.5), described_class.value(-0.1), described_class.value(Float::NAN),
      described_class.value(true),
      described_class.pass(label: "x" * 257), described_class.pass(label: 7),
      described_class.pass(metadata: { "text" => "x" * 4_100 }), described_class.pass(metadata: [1]),
      described_class.pass(metadata: { "at" => Time.now }), described_class.match(Time.now, "x"),
      described_class.pass(7)
    ]

    expect(invalid.map(&:status).uniq).to eq([:unscored])
    expect(invalid.map { _1.reason["code"] }.uniq).to eq(["score_invalid"])
    expect(invalid.map(&:passed).uniq).to eq([nil])
  end

  it "keeps at most 4 KiB of explanation, marking the cut, and a label of 256 bytes" do
    score = described_class.pass("é" * 3_000, label: "x" * 256)

    expect(score.explanation.bytesize).to be <= 4_096
    expect(score.explanation).to end_with("...[truncated]")
    expect(score.label.bytesize).to eq(256)
    expect(described_class.pass(metadata: { "text" => "x" * 4_000 }).status).to eq(:scored)
  end

  it "gives the trial line's score fields, as the published examples write them" do
    expect(described_class.match("shipping", "shipping").to_h)
      .to eq("status" => "scored", "passed" => true, "value" => 1, "label" => nil, "explanation" => "matched shipping",
             "metadata" => nil, "reason" => nil)
    expect(described_class.value(0.5).to_h).to include("passed" => nil, "value" => 0.5)
    expect(described_class.unscored("no priority").to_h)
      .to include("status" => "unscored", "passed" => nil, "value" => nil,
                  "reason" => { "code" => "grader_undecided", "by" => "grader", "detail" => "no priority" })
  end
end
