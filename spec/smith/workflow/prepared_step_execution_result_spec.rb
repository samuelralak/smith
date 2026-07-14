# frozen_string_literal: true

RSpec.describe Smith::Workflow::PreparedStepExecutionResult do
  it "owns a successful step result" do
    step = { transition: :finish, from: :idle, to: :done, output: { "items" => [+"done"] } }

    result = described_class.from_step(step)
    step.fetch(:output).fetch("items").first.replace("changed")

    expect(result).to be_succeeded
    expect(result).not_to be_failed
    expect(result.error).to be_nil
    expect(result.step).to include(output: { "items" => ["done"] })
    expect(result.step).to be_frozen
    expect(result.step.fetch(:output)).to be_frozen
    expect(result.step.dig(:output, "items")).to be_frozen
    expect(result.step.dig(:output, "items", 0)).to be_frozen
    expect(result).to be_frozen
  end

  it "owns cyclic JSON-like step values in linear time and space" do
    output = []
    output << output

    result = described_class.from_step(transition: :finish, from: :idle, to: :done, output:)

    copied = result.step.fetch(:output)
    expect(copied.first).to equal(copied)
    expect(copied).to be_frozen
  end

  it "rejects excessive nesting without overflowing the Ruby stack" do
    output = []
    cursor = output
    200.times do
      nested = []
      cursor << nested
      cursor = nested
    end

    expect do
      described_class.from_step(transition: :finish, from: :idle, to: :done, output:)
    end.to raise_error(Smith::WorkflowError, /maximum depth/)
  end

  it "rejects mutable values outside the durable result contract" do
    mutable = Struct.new(:value).new("before")

    expect do
      described_class.from_step(transition: :finish, from: :idle, to: :done, output: mutable)
    end.to raise_error(Smith::WorkflowError, /unsupported mutable value/)
  end

  it "returns an independent mutable snapshot for the legacy API" do
    result = described_class.from_step(
      transition: :finish,
      from: :idle,
      to: :done,
      output: { "items" => ["done"] }
    )

    snapshot = result.step_snapshot
    snapshot.fetch(:output).fetch("items").first.replace("changed")

    expect(snapshot.dig(:output, "items")).to eq(["changed"])
    expect(result.step.dig(:output, "items")).to eq(["done"])
  end

  it "preserves a transition failure independently of workflow routing" do
    error = Smith::AgentError.new("provider failed")

    result = described_class.from_step(
      transition: :answer,
      from: :idle,
      to: :failed,
      error:
    )

    expect(result).to be_failed
    expect(result).not_to be_succeeded
    expect(result.error).to equal(error)
    expect(result.step.fetch(:error)).to equal(error)
  end

  it "rejects nested exception aliases" do
    error = Smith::AgentError.new("nested provider failure")

    expect do
      described_class.from_step(
        transition: :finish,
        from: :idle,
        to: :done,
        output: { error: }
      )
    end.to raise_error(Smith::WorkflowError, /unsupported mutable value/)
  end

  it "rejects custom numeric objects outside the durable result contract" do
    numeric_class = Class.new(Numeric)

    expect do
      described_class.from_step(
        transition: :finish,
        from: :idle,
        to: :done,
        output: numeric_class.new
      )
    end.to raise_error(Smith::WorkflowError, /unsupported mutable value/)
  end

  it "rejects container-valued Hash keys before they can corrupt the snapshot" do
    expect do
      described_class.from_step(
        transition: :finish,
        from: :idle,
        to: :done,
        output: { ["key"] => "value" }
      )
    end.to raise_error(Smith::WorkflowError, /unsupported Hash key/)
  end

  it "rejects non-finite Floats outside the JSON-like result contract" do
    [Float::INFINITY, -Float::INFINITY, Float::NAN].each do |value|
      expect do
        described_class.from_step(
          transition: :finish,
          from: :idle,
          to: :done,
          output: value
        )
      end.to raise_error(Smith::WorkflowError, /non-finite Float/)
    end
  end

  it "rejects status and error shape mismatches" do
    error = Smith::AgentError.new("provider failed")

    expect do
      described_class.new(status: :succeeded, step: { error: }, error:)
    end.to raise_error(ArgumentError, /do not match/)
    expect do
      described_class.new(status: :failed, step: {}, error: nil)
    end.to raise_error(ArgumentError, /do not match/)
  end
end
