# frozen_string_literal: true

RSpec.describe Smith::Tool::Compatibility do
  def build_profile(provider:, endpoint_mode: :chat_completions)
    Smith::Models::Profile.new(
      model_id:                   "test-model",
      provider:                   provider,
      thinking_shape:             :reasoning_effort,
      accepts_temperature:        true,
      tools_with_thinking_native: false,
      tools_with_thinking_route:  endpoint_mode == :responses ? :responses : nil
    )
  end

  describe ".parse" do
    it "parses positional providers into a Set allowlist" do
      spec = described_class.parse([:anthropic, :gemini], except: nil)
      expect(spec[:providers]).to eq(Set[:anthropic, :gemini])
      expect(spec[:endpoints]).to eq({})
      expect(spec[:except]).to be_nil
    end

    it "merges keyword-style endpoint constraints into providers" do
      spec = described_class.parse([:anthropic], except: nil, openai: :responses)
      expect(spec[:providers]).to eq(Set[:anthropic, :openai])
      expect(spec[:endpoints]).to eq(openai: Set[:responses])
    end

    it "parses except clauses" do
      spec = described_class.parse([], except: { openai: :chat_completions })
      expect(spec[:providers]).to be_nil
      expect(spec[:except]).to eq(openai: Set[:chat_completions])
    end

    it "freezes the resulting spec hash" do
      spec = described_class.parse([:anthropic], except: nil)
      expect(spec).to be_frozen
    end
  end

  describe ".allows?" do
    context "with no spec (universal compatibility)" do
      it "returns true for any profile" do
        expect(described_class.allows?(nil, build_profile(provider: :anthropic))).to be(true)
        expect(described_class.allows?(nil, build_profile(provider: :openai))).to be(true)
      end
    end

    context "with a providers allowlist" do
      let(:spec) { described_class.parse([:anthropic, :gemini], except: nil) }

      it "allows providers on the allowlist" do
        expect(described_class.allows?(spec, build_profile(provider: :anthropic))).to be(true)
        expect(described_class.allows?(spec, build_profile(provider: :gemini))).to be(true)
      end

      it "denies providers not on the allowlist" do
        expect(described_class.allows?(spec, build_profile(provider: :openai))).to be(false)
      end
    end

    context "with provider + endpoint constraints" do
      # Think's actual spec: Anthropic (any endpoint), Gemini (any),
      # OpenAI (only :responses endpoint).
      let(:spec) { described_class.parse([:anthropic, :gemini], except: nil, openai: :responses) }

      it "allows Anthropic on chat_completions endpoint" do
        expect(described_class.allows?(spec, build_profile(provider: :anthropic, endpoint_mode: :chat_completions))).to be(true)
      end

      it "allows OpenAI ONLY on the :responses endpoint" do
        expect(described_class.allows?(spec, build_profile(provider: :openai, endpoint_mode: :responses))).to be(true)
      end

      it "denies OpenAI on the :chat_completions endpoint" do
        expect(described_class.allows?(spec, build_profile(provider: :openai, endpoint_mode: :chat_completions))).to be(false)
      end
    end

    context "with except clauses" do
      let(:spec) { described_class.parse([], except: { openai: :chat_completions }) }

      it "denies the excluded provider+endpoint combo" do
        expect(described_class.allows?(spec, build_profile(provider: :openai, endpoint_mode: :chat_completions))).to be(false)
      end

      it "allows OpenAI on other endpoints" do
        expect(described_class.allows?(spec, build_profile(provider: :openai, endpoint_mode: :responses))).to be(true)
      end

      it "allows providers not in except" do
        expect(described_class.allows?(spec, build_profile(provider: :anthropic))).to be(true)
      end
    end
  end

  describe "Smith::Tool DSL integration" do
    it "stores the parsed spec on the class via compatible_with_spec" do
      tool_class = Class.new(Smith::Tool) do
        compatible_with :anthropic, openai: :responses
      end

      spec = tool_class.compatible_with_spec
      expect(spec[:providers]).to eq(Set[:anthropic, :openai])
      expect(spec[:endpoints]).to eq(openai: Set[:responses])
    end

    it "propagates compatible_with_spec to subclasses via the inherited hook" do
      parent = Class.new(Smith::Tool) do
        compatible_with :anthropic
      end
      child = Class.new(parent)

      expect(child.compatible_with_spec).to eq(parent.compatible_with_spec)
    end

    it "allows subclasses to override compatible_with without affecting parent" do
      parent = Class.new(Smith::Tool) do
        compatible_with :anthropic
      end
      child = Class.new(parent) do
        compatible_with :gemini
      end

      expect(parent.compatible_with_spec[:providers]).to eq(Set[:anthropic])
      expect(child.compatible_with_spec[:providers]).to eq(Set[:gemini])
    end
  end

  describe "Smith::Tools::Think pre-declared spec" do
    it "is compatible with Anthropic on any endpoint" do
      profile = build_profile(provider: :anthropic, endpoint_mode: :chat_completions)
      expect(described_class.allows?(Smith::Tools::Think.compatible_with_spec, profile)).to be(true)
    end

    it "is compatible with Gemini on any endpoint" do
      profile = build_profile(provider: :gemini, endpoint_mode: :chat_completions)
      expect(described_class.allows?(Smith::Tools::Think.compatible_with_spec, profile)).to be(true)
    end

    it "is compatible with OpenAI ONLY on :responses endpoint" do
      responses_profile = build_profile(provider: :openai, endpoint_mode: :responses)
      chat_profile = build_profile(provider: :openai, endpoint_mode: :chat_completions)
      expect(described_class.allows?(Smith::Tools::Think.compatible_with_spec, responses_profile)).to be(true)
      expect(described_class.allows?(Smith::Tools::Think.compatible_with_spec, chat_profile)).to be(false)
    end
  end
end
