# frozen_string_literal: true

require "spec_helper"

RSpec.describe Smith::Agent::ProviderCandidateSequence do
  subject(:sequence) { described_class.new(references) }

  let(:model_reference) { Smith::Agent::ModelReference }
  let(:references) do
    [
      model_reference.new(model_id: "legacy-primary", provider: nil),
      model_reference.new(model_id: "openai-fallback", provider: :openai),
      model_reference.new(model_id: "anthropic-fallback", provider: :anthropic)
    ]
  end

  it "suppresses only remaining candidates for an unavailable provider" do
    yielded = []

    sequence.each do |reference, index|
      yielded << [reference.provider, index]
      sequence.suppress(:openai) if index.zero?
    end

    expect(yielded).to eq([[nil, 0], [:anthropic, 2]])
    expect(sequence).not_to be_fallback_available
  end

  it "retains candidates from other providers" do
    yielded = []

    sequence.each do |reference, index|
      yielded << [reference.model_id, index]
      next unless index.zero?

      sequence.suppress(:openai)
      expect(sequence).to be_fallback_available
    end

    expect(yielded).to eq(
      [["legacy-primary", 0], ["anthropic-fallback", 2]]
    )
    expect(sequence).not_to be_fallback_available
  end

  it "yields nothing for an empty chain and never exposes the references as a result" do
    sequence = described_class.new([])
    yielded = []

    returned = sequence.each { |reference, index| yielded << [reference, index] }

    expect(yielded).to be_empty
    expect(returned).to be(sequence)
    expect(sequence).not_to be_fallback_available
  end
end
