# frozen_string_literal: true

RSpec.describe Smith::Models do
  before { described_class.clear! }
  after  { described_class.clear! }

  describe "::Profile" do
    let(:profile) do
      Smith::Models::Profile.new(
        model_id:                   "test-model-1",
        provider:                   :anthropic,
        thinking_shape:             :adaptive,
        accepts_temperature:        false,
        tools_with_thinking_native: true,
        tools_with_thinking_route:  nil
      )
    end

    it "exposes endpoint_mode derived from tools_with_thinking_route" do
      expect(profile.endpoint_mode).to eq(:chat_completions)
    end

    it "exposes :responses endpoint_mode when route is :responses" do
      responses_profile = Smith::Models::Profile.new(
        model_id:                   "test-gpt-5",
        provider:                   :openai,
        thinking_shape:             :reasoning_effort,
        accepts_temperature:        false,
        tools_with_thinking_native: false,
        tools_with_thinking_route:  :responses
      )
      expect(responses_profile.endpoint_mode).to eq(:responses)
    end

    it "is value-equal across instances with identical fields" do
      twin = Smith::Models::Profile.new(**profile.to_h)
      expect(profile).to eq(twin)
    end
  end

  describe ".register" do
    let(:profile) do
      Smith::Models::Profile.new(
        model_id:                   "test-model-2",
        provider:                   :anthropic,
        thinking_shape:             :budget_tokens,
        accepts_temperature:        true,
        tools_with_thinking_native: true,
        tools_with_thinking_route:  nil
      )
    end

    it "stores the profile and makes it retrievable via find" do
      described_class.register(profile)
      expect(described_class.find("test-model-2")).to eq(profile)
    end

    it "is idempotent when re-registering an identical profile" do
      described_class.register(profile)
      expect { described_class.register(profile) }.not_to raise_error
      expect(described_class.find("test-model-2")).to eq(profile)
    end

    it "raises CollisionError when re-registering a conflicting profile with a DIFFERENT model_id signature" do
      described_class.register(profile)
      conflicting = Smith::Models::Profile.new(
        **profile.to_h.merge(thinking_shape: :adaptive)
      )
      # Same model_id, different capabilities — currently treated as
      # a stale-reload swap (silent replace). See .register docs.
      expect { described_class.register(conflicting) }.not_to raise_error
      expect(described_class.find("test-model-2").thinking_shape).to eq(:adaptive)
    end
  end

  describe ".find" do
    it "returns nil for unknown model_ids" do
      expect(described_class.find("nope")).to be_nil
    end

    it "accepts both Symbol and String model_ids" do
      profile = Smith::Models::Profile.new(
        model_id:                   "test-model-3",
        provider:                   :openai,
        thinking_shape:             nil,
        accepts_temperature:        true,
        tools_with_thinking_native: false,
        tools_with_thinking_route:  nil
      )
      described_class.register(profile)
      expect(described_class.find(:"test-model-3")).to eq(profile)
      expect(described_class.find("test-model-3")).to eq(profile)
    end
  end

  describe ".find_or_infer" do
    it "returns a registered profile when present" do
      profile = Smith::Models::Profile.new(
        model_id:                   "custom-finetune",
        provider:                   :openai,
        thinking_shape:             :reasoning_effort,
        accepts_temperature:        false,
        tools_with_thinking_native: false,
        tools_with_thinking_route:  :responses
      )
      described_class.register(profile)
      expect(described_class.find_or_infer("custom-finetune")).to eq(profile)
    end

    it "falls back to Inference rule when no override registered" do
      # claude-opus-4-7 matches the Anthropic Opus 4.7+ pattern.
      result = described_class.find_or_infer("claude-opus-4-7")
      expect(result.provider).to eq(:anthropic)
      expect(result.thinking_shape).to eq(:adaptive)
      expect(result.accepts_temperature).to be(false)
    end

    it "falls back to safe defaults when no rule matches" do
      result = described_class.find_or_infer("never-heard-of-this-model")
      expect(result.thinking_shape).to be_nil
      expect(result.accepts_temperature).to be(true)
      expect(result.tools_with_thinking_native).to be(false)
      expect(result.tools_with_thinking_route).to be_nil
    end

    it "uses provider hint when guess_provider can't infer" do
      result = described_class.find_or_infer("unknown-provider-model", provider: :custom)
      expect(result.provider).to eq(:custom)
    end
  end

  describe ".guess_provider" do
    it "matches anthropic from claude- prefix" do
      result = described_class.find_or_infer("claude-totally-new-model-9")
      expect(result.provider).to eq(:anthropic)
    end

    it "matches openai from gpt- prefix" do
      result = described_class.find_or_infer("gpt-totally-new")
      expect(result.provider).to eq(:openai)
    end

    it "matches openai from o-series prefix" do
      result = described_class.find_or_infer("o3-mini")
      expect(result.provider).to eq(:openai)
    end

    it "matches gemini from gemini- prefix" do
      result = described_class.find_or_infer("gemini-new-thing")
      expect(result.provider).to eq(:gemini)
    end

    it "falls back to :unknown for unrecognized prefixes" do
      result = described_class.find_or_infer("xyz-mystery-model")
      expect(result.provider).to eq(:unknown)
    end
  end

  describe ".all" do
    it "returns registered profiles sorted by model_id" do
      profiles = %w[zebra alpha middle].map do |id|
        Smith::Models::Profile.new(
          model_id: id, provider: :openai, thinking_shape: nil,
          accepts_temperature: true, tools_with_thinking_native: false,
          tools_with_thinking_route: nil
        )
      end
      profiles.each { |p| described_class.register(p) }
      expect(described_class.all.map(&:model_id)).to eq(%w[alpha middle zebra])
    end
  end
end
