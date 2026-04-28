# frozen_string_literal: true

RSpec.describe Smith::Pricing do
  around do |example|
    original = Smith.config.pricing
    example.run
  ensure
    Smith.configure { |c| c.pricing = original }
  end

  describe ".compute_cost" do
    it "returns nil when no pricing config is set" do
      Smith.configure { |c| c.pricing = nil }
      expect(described_class.compute_cost(model: "any", input_tokens: 100, output_tokens: 50)).to be_nil
    end

    it "returns nil when the model isn't in the catalog" do
      Smith.configure do |c|
        c.pricing = { "known-model" => { input_cost_per_token: 0.001, output_cost_per_token: 0.002 } }
      end
      expect(described_class.compute_cost(model: "unknown", input_tokens: 100, output_tokens: 50)).to be_nil
    end

    describe "flat-shape pricing" do
      before do
        Smith.configure do |c|
          c.pricing = { "flat-model" => { input_cost_per_token: 0.001, output_cost_per_token: 0.002 } }
        end
      end

      it "computes input * input_rate + output * output_rate" do
        expect(described_class.compute_cost(model: "flat-model", input_tokens: 100, output_tokens: 50))
          .to eq(0.001 * 100 + 0.002 * 50)
      end

      it "returns nil when rates are not Numeric" do
        Smith.configure do |c|
          c.pricing = { "broken" => { input_cost_per_token: "0.001", output_cost_per_token: 0.002 } }
        end
        expect(described_class.compute_cost(model: "broken", input_tokens: 100, output_tokens: 50)).to be_nil
      end
    end

    describe "tiered-shape pricing" do
      before do
        Smith.configure do |c|
          c.pricing = {
            "tiered-model" => {
              tiers: [
                { max_input_tokens: 200_000, input_cost_per_token: 0.001, output_cost_per_token: 0.010 },
                { max_input_tokens: nil,     input_cost_per_token: 0.002, output_cost_per_token: 0.015 }
              ]
            }
          }
        end
      end

      it "picks the first tier when input_tokens is at or below max_input_tokens" do
        # exactly at threshold
        expect(described_class.compute_cost(model: "tiered-model", input_tokens: 200_000, output_tokens: 1_000))
          .to eq(0.001 * 200_000 + 0.010 * 1_000)
      end

      it "picks the second tier when input_tokens exceeds the first tier's ceiling" do
        # one over threshold
        expect(described_class.compute_cost(model: "tiered-model", input_tokens: 200_001, output_tokens: 1_000))
          .to eq(0.002 * 200_001 + 0.015 * 1_000)
      end

      it "treats nil max_input_tokens as the unbounded ceiling" do
        # very large input — second tier's nil max catches it
        expect(described_class.compute_cost(model: "tiered-model", input_tokens: 999_999, output_tokens: 0))
          .to eq(0.002 * 999_999)
      end

      it "accepts string keys in the tier hash (JSON round-trip safety)" do
        Smith.configure do |c|
          c.pricing = {
            "string-keyed" => {
              "tiers" => [
                { "max_input_tokens" => nil, "input_cost_per_token" => 0.005, "output_cost_per_token" => 0.025 }
              ]
            }
          }
        end
        expect(described_class.compute_cost(model: "string-keyed", input_tokens: 10, output_tokens: 5))
          .to eq(0.005 * 10 + 0.025 * 5)
      end
    end
  end
end
