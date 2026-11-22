# frozen_string_literal: true

require "json"
require "smith/evals/statistics"

RSpec.describe Smith::Evals::Statistics::SplitMix64 do
  reference = JSON.parse(File.read(File.expand_path("../../../fixtures/evals/statistics_reference.json", __dir__)))
  vectors = reference.fetch("splitmix64")

  it "draws the published SplitMix64 vectors exactly" do
    { "seed_0" => 0, "seed_1234567" => 1_234_567 }.each do |name, seed|
      generator = described_class.new(seed)
      expect(Array.new(5) { format("%016x", generator.next_u64) }).to eq(vectors.fetch(name)), name
    end
    expect(vectors["seed_0"].first).to eq("e220a8397b1dcdaf")
    expect(vectors["seed_1234567"].first).to eq("599ed017fb08fc85")
  end

  it "draws twelve integers below 37 from seed 42 exactly, by rejection" do
    generator = described_class.new(42)

    expect(Array.new(12) { generator.below(37) }).to eq(vectors.fetch("below_37_seed_42"))
  end

  it "takes a seed as the 16 hex digits a result records" do
    expect(described_class.from_hex("000000000012d687").next_u64).to eq(described_class.new(1_234_567).next_u64)
    ["12d687", "000000000012D687", 1_234_567, nil].each do |hex|
      expect { described_class.from_hex(hex) }.to raise_error(ArgumentError, /16 lowercase hex/)
    end
  end

  it "keeps its state to 64 bits and refuses a seed or a bound outside them" do
    generator = described_class.new((2**64) - 1)

    expect(Array.new(1_000) { generator.next_u64 }).to all(be_between(0, (2**64) - 1))
    expect(Array.new(100) { generator.below(1) }.uniq).to eq([0])
    expect(described_class.new(0).below(2**64)).to eq(0xe220a8397b1dcdaf)
    [-1, 2**64, 1.5, "1"].each { |seed| expect { described_class.new(seed) }.to raise_error(ArgumentError) }
    [0, (2**64) + 1, 2.0].each { |bound| expect { generator.below(bound) }.to raise_error(ArgumentError) }
  end
end
