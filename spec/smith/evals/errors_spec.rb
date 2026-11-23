# frozen_string_literal: true

require "smith/evals"

RSpec.describe "Smith::Evals errors" do
  it "are all Smith::Evals::Error, itself a Smith::Error" do
    names = %i[SuiteInvalid DatasetInvalid DatasetChanged SplitNotAllowed SubjectNotReady DriverUnsupported
               ResumeMismatch RunBusy RecordCorrupt StoreError]

    expect(Smith::Evals::Error.superclass).to eq(Smith::Error)
    expect(names.map { Smith::Evals.const_get(_1).superclass }.uniq).to eq([Smith::Evals::Error])
  end

  it "keeps a suite's problems, at most 100, and names them in its message" do
    error = Smith::Evals::SuiteInvalid.new((1..150).map { "/trials/per_sample: problem #{_1}" }, suite: "demo")

    expect(error.problems.size).to eq(100)
    expect(error.problems.first).to eq("/trials/per_sample: problem 1")
    expect(error.problems).to be_frozen
    expect(error.message).to start_with("suite demo is invalid: /trials/per_sample: problem 1; ")
  end

  it "names the parts, fields, line and operation each carries" do
    expect(Smith::Evals::DatasetChanged.new("changed", parts: %i[inputs labels]).parts).to eq(%w[inputs labels])
    expect(Smith::Evals::ResumeMismatch.new("differs", fields: ["suite version"]).fields).to eq(["suite version"])
    expect(Smith::Evals::RecordCorrupt.new("bad line", line: 12).line).to eq(12)
    expect(Smith::Evals::StoreError.new("failed", operation: :append_trial).operation).to eq(:append_trial)
  end
end
