# frozen_string_literal: true

require "spec_helper"

RSpec.describe Smith::Agent::ModelReference do
  describe ".coerce" do
    it "parses the provider/model string form emitted by #to_s" do
      reference = described_class.coerce("openai/gpt-5-mini")

      expect(reference.to_h).to eq(model_id: "gpt-5-mini", provider: :openai)
    end

    it "round-trips a reference whose model id itself contains slashes" do
      reference = described_class.new(model_id: "openai/gpt-5", provider: :openrouter)

      expect(reference.to_s).to eq("openrouter/openai/gpt-5")
      expect(described_class.coerce(reference.to_s).to_h).to eq(reference.to_h)
    end

    it "keeps a slashed string literal when an explicit provider is given" do
      reference = described_class.coerce("openai/gpt-5", provider: :openrouter)

      expect(reference.to_h).to eq(model_id: "openai/gpt-5", provider: :openrouter)
    end

    it "leaves slashless strings provider-unqualified" do
      expect(described_class.coerce("gpt-5-mini").to_h).to eq(model_id: "gpt-5-mini", provider: nil)
    end

    it "rejects a blank provider segment" do
      expect { described_class.coerce("/gpt-5") }
        .to raise_error(ArgumentError, /provider segment/)
    end

    it "rejects a blank model segment" do
      expect { described_class.coerce("openai/") }
        .to raise_error(Dry::Struct::Error, /must not be blank/)
    end
  end

  describe "#same_candidate?" do
    it "matches an unqualified reference against a qualified one with the same model id" do
      unqualified = described_class.new(model_id: "gpt-5-mini", provider: nil)
      qualified = described_class.new(model_id: "gpt-5-mini", provider: :openai)

      expect(unqualified.same_candidate?(qualified)).to be(true)
      expect(qualified.same_candidate?(unqualified)).to be(true)
    end

    it "does not match different providers or different model ids" do
      openai = described_class.new(model_id: "gpt-5-mini", provider: :openai)
      openrouter = described_class.new(model_id: "gpt-5-mini", provider: :openrouter)
      other = described_class.new(model_id: "gpt-4.1-nano", provider: :openai)

      expect(openai.same_candidate?(openrouter)).to be(false)
      expect(openai.same_candidate?(other)).to be(false)
    end
  end
end
