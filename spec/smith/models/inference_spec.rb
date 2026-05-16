# frozen_string_literal: true

RSpec.describe Smith::Models::Inference do
  describe ".profile_for — Anthropic family" do
    it "matches Opus 4.7+ to adaptive thinking + no temperature" do
      profile = described_class.profile_for("claude-opus-4-7")
      expect(profile).not_to be_nil
      expect(profile.provider).to eq(:anthropic)
      expect(profile.thinking_shape).to eq(:adaptive)
      expect(profile.accepts_temperature).to be(false)
      expect(profile.tools_with_thinking_native).to be(true)
      expect(profile.tools_with_thinking_route).to be_nil
    end

    it "matches a hypothetical Opus 4.10 to adaptive (version-aware predicate)" do
      profile = described_class.profile_for("claude-opus-4-10")
      expect(profile.thinking_shape).to eq(:adaptive)
    end

    it "matches Opus 4.6 to budget_tokens (NOT adaptive)" do
      profile = described_class.profile_for("claude-opus-4-6")
      expect(profile.thinking_shape).to eq(:budget_tokens)
      expect(profile.accepts_temperature).to be(true)
    end

    it "matches Sonnet 4.5 to budget_tokens" do
      profile = described_class.profile_for("claude-sonnet-4-5")
      expect(profile.thinking_shape).to eq(:budget_tokens)
    end

    it "matches Claude 3.7 Sonnet to budget_tokens" do
      profile = described_class.profile_for("claude-3-7-sonnet")
      expect(profile.thinking_shape).to eq(:budget_tokens)
    end

    it "matches Claude 3.5 to no thinking (3.5 family doesn't have extended thinking)" do
      profile = described_class.profile_for("claude-3-5-sonnet")
      expect(profile.thinking_shape).to be_nil
    end

    it "matches any other Claude to safe default (no thinking)" do
      profile = described_class.profile_for("claude-future-model")
      expect(profile.provider).to eq(:anthropic)
      expect(profile.thinking_shape).to be_nil
    end
  end

  describe ".profile_for — OpenAI family" do
    it "matches gpt-5 family to reasoning_effort + responses route + no temperature" do
      profile = described_class.profile_for("gpt-5.5")
      expect(profile.provider).to eq(:openai)
      expect(profile.thinking_shape).to eq(:reasoning_effort)
      expect(profile.accepts_temperature).to be(false)
      expect(profile.tools_with_thinking_native).to be(false)
      expect(profile.tools_with_thinking_route).to eq(:responses)
    end

    it "matches o-series to reasoning_effort + responses route" do
      profile = described_class.profile_for("o3-mini")
      expect(profile.thinking_shape).to eq(:reasoning_effort)
      expect(profile.tools_with_thinking_route).to eq(:responses)
    end

    it "matches gpt-4.x to no thinking + accepts temperature" do
      profile = described_class.profile_for("gpt-4.1-mini")
      expect(profile.thinking_shape).to be_nil
      expect(profile.accepts_temperature).to be(true)
      expect(profile.tools_with_thinking_route).to be_nil
    end

    it "matches gpt-3.x to no thinking" do
      profile = described_class.profile_for("gpt-3.5-turbo")
      expect(profile.thinking_shape).to be_nil
    end
  end

  describe ".profile_for — Gemini family" do
    it "matches Gemini 2.5+ to budget_tokens thinking" do
      profile = described_class.profile_for("gemini-2.5-pro")
      expect(profile.provider).to eq(:gemini)
      expect(profile.thinking_shape).to eq(:budget_tokens)
      expect(profile.tools_with_thinking_native).to be(true)
    end

    it "matches Gemini 2.5 Flash to budget_tokens (NOT only Pro)" do
      profile = described_class.profile_for("gemini-2.5-flash")
      expect(profile.thinking_shape).to eq(:budget_tokens)
    end

    it "matches Gemini 3.x (hypothetical future) to budget_tokens" do
      profile = described_class.profile_for("gemini-3.0-ultra")
      expect(profile.thinking_shape).to eq(:budget_tokens)
    end

    it "matches Gemini 1.x to no thinking" do
      profile = described_class.profile_for("gemini-1.5-pro")
      expect(profile.thinking_shape).to be_nil
    end

    it "matches Gemini 2.0 to no thinking" do
      profile = described_class.profile_for("gemini-2.0-flash")
      expect(profile.thinking_shape).to be_nil
    end
  end

  describe ".profile_for — no rule match" do
    it "returns nil for unrecognized model_ids" do
      expect(described_class.profile_for("totally-unknown-model")).to be_nil
    end
  end

  describe ".with_rules" do
    after { described_class.reset! }

    it "yields with the given rules and restores afterward" do
      custom_rule = described_class::Rule.new(
        provider: :anthropic,
        matcher:  ->(_id) { true },
        thinking_shape: :adaptive,
        accepts_temperature: false,
        tools_with_thinking_native: true,
        tools_with_thinking_route: nil
      )

      original_rules = described_class.rules

      described_class.with_rules(custom_rule) do
        expect(described_class.rules).to eq([custom_rule])
        # Every model_id matches the catch-all custom rule.
        expect(described_class.profile_for("anything").thinking_shape).to eq(:adaptive)
      end

      expect(described_class.rules).to eq(original_rules)
    end

    it "restores rules even when the block raises" do
      original_count = described_class.rules.size
      expect do
        described_class.with_rules([]) { raise "boom" }
      end.to raise_error("boom")
      expect(described_class.rules.size).to eq(original_count)
    end
  end

  describe ".prepend_rule" do
    after { described_class.reset! }

    it "places the new rule ahead of defaults (higher precedence)" do
      custom_rule = described_class::Rule.new(
        provider: :openai,
        matcher:  ->(id) { id == "custom-special" },
        thinking_shape: :reasoning_effort,
        accepts_temperature: false,
        tools_with_thinking_native: true,
        tools_with_thinking_route: nil
      )
      described_class.prepend_rule(custom_rule)
      profile = described_class.profile_for("custom-special")
      expect(profile.tools_with_thinking_native).to be(true)  # custom rule
    end
  end
end
