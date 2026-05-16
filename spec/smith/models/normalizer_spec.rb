# frozen_string_literal: true

RSpec.describe Smith::Models::Normalizer do
  # Stub API keys so RubyLLM::Provider validation passes — the
  # normalizer never makes actual HTTP calls, but RubyLLM::Chat.new
  # constructs a Provider which validates config before doing anything.
  before(:each) do
    RubyLLM.configure do |config|
      config.anthropic_api_key = "test-anthropic-key"
      config.openai_api_key    = "test-openai-key"
      config.gemini_api_key    = "test-gemini-key"
    end
  end

  # Build a real RubyLLM::Chat for the normalizer to mutate. Using a real
  # chat (not a double) is important because the normalizer reaches into
  # @temperature/@thinking/@params ivars; doubles would mask bugs in that
  # contract. Provider hint required when assume_model_exists is true.
  def build_chat(model: "claude-opus-4-7", provider: nil)
    inferred_provider = provider || Smith::Models.find_or_infer(model).provider
    RubyLLM.chat(model: model, provider: inferred_provider, assume_model_exists: true)
  end

  describe "Opus 4.7 adaptive thinking translation (replaces monkey-patch)" do
    let(:profile) { Smith::Models.find_or_infer("claude-opus-4-7") }
    let(:chat) do
      c = build_chat
      c.with_thinking(effort: "xhigh")
      c.with_temperature(1.0)
      c
    end

    it "translates @thinking into params[:thinking] = {type: 'adaptive'}" do
      described_class.apply!(chat, profile: profile)
      expect(chat.instance_variable_get(:@params)).to include(
        thinking: { type: "adaptive" }
      )
    end

    it "preserves the configured effort in params[:output_config][:effort]" do
      described_class.apply!(chat, profile: profile)
      expect(chat.instance_variable_get(:@params)[:output_config]).to eq(effort: "xhigh")
    end

    it "defaults effort to 'high' when thinking config has no explicit effort" do
      c = build_chat
      c.with_thinking(budget: 16_384)
      c.with_temperature(1.0)
      described_class.apply!(c, profile: profile)
      expect(c.instance_variable_get(:@params)[:output_config]).to eq(effort: "high")
    end

    it "nulls @thinking after translating to adaptive (prevents RubyLLM from emitting budget_tokens too)" do
      described_class.apply!(chat, profile: profile)
      expect(chat.instance_variable_get(:@thinking)).to be_nil
    end

    it "nulls @temperature (Opus 4.7 doesn't accept temperature)" do
      described_class.apply!(chat, profile: profile)
      expect(chat.instance_variable_get(:@temperature)).to be_nil
    end

    it "preserves prior with_params(...) calls when injecting adaptive thinking" do
      c = build_chat
      c.with_thinking(effort: "high")
      c.with_temperature(1.0)
      c.with_params(custom_key: "kept")
      described_class.apply!(c, profile: profile)
      params = c.instance_variable_get(:@params)
      expect(params[:custom_key]).to eq("kept")
      expect(params[:thinking]).to eq(type: "adaptive")
    end
  end

  # gpt-5 family routing tests live in spec/smith/providers/openai/routing_spec.rb
  # (added in commit A4 when Smith.config.openai_api_mode is introduced).
  # The normalizer's tools_routing logic is exercised end-to-end through
  # the routing prepend, not in isolation here.

  describe "models with no thinking shape (gpt-4.1-mini)" do
    let(:profile) { Smith::Models.find_or_infer("gpt-4.1-mini") }

    it "nulls @thinking when profile.thinking_shape is nil and thinking was configured" do
      c = build_chat(model: "gpt-4.1-mini")
      c.with_thinking(effort: "high")
      described_class.apply!(c, profile: profile)
      expect(c.instance_variable_get(:@thinking)).to be_nil
    end
  end

  describe "models with native budget_tokens (Opus 4.6, Gemini 2.5)" do
    it "leaves @thinking unchanged for Opus 4.6 (RubyLLM emits budget_tokens natively)" do
      profile = Smith::Models.find_or_infer("claude-opus-4-6")
      c = build_chat(model: "claude-opus-4-6")
      c.with_thinking(budget: 8192)
      described_class.apply!(c, profile: profile)
      thinking = c.instance_variable_get(:@thinking)
      expect(thinking).not_to be_nil
      expect(thinking.budget).to eq(8192)
    end

    it "leaves @thinking unchanged for Gemini 2.5 (also budget_tokens)" do
      profile = Smith::Models.find_or_infer("gemini-2.5-pro")
      c = build_chat(model: "gemini-2.5-pro")
      c.with_thinking(budget: 8192)
      described_class.apply!(c, profile: profile)
      expect(c.instance_variable_get(:@thinking)).not_to be_nil
    end
  end

  describe "Decision tracing" do
    it "returns Decision records for each mutation" do
      profile = Smith::Models.find_or_infer("claude-opus-4-7")
      chat = build_chat
      chat.with_thinking(effort: "high")
      chat.with_temperature(0.7)
      decisions = described_class.apply!(chat, profile: profile)
      kinds = decisions.map(&:kind)
      expect(kinds).to include(:temperature_dropped, :thinking_translated_to_adaptive)
    end

    it "returns an empty array when no mutations are needed" do
      profile = Smith::Models.find_or_infer("gpt-4.1-mini")
      chat = build_chat(model: "gpt-4.1-mini")
      chat.with_temperature(0.5)
      decisions = described_class.apply!(chat, profile: profile)
      expect(decisions).to eq([])
    end

    it "is a no-op when profile is nil" do
      chat = build_chat
      expect { described_class.apply!(chat, profile: nil) }.not_to raise_error
    end

    it "emits :normalizer_decision trace events when trace_normalizer is true (default)" do
      Smith.config.trace_adapter = Smith::Trace::Memory.new
      profile = Smith::Models.find_or_infer("claude-opus-4-7")
      chat = build_chat
      chat.with_thinking(effort: "xhigh")
      chat.with_temperature(1.0)

      described_class.apply!(chat, profile: profile)

      traced = Smith.config.trace_adapter.traces.select { |t| t[:type] == :normalizer_decision }
      expect(traced).not_to be_empty
      kinds = traced.map { |t| t[:data][:kind] }
      expect(kinds).to include(:thinking_translated_to_adaptive, :temperature_dropped)
    ensure
      Smith.config.trace_adapter = nil
    end

    it "is gated by Smith.config.trace_normalizer = false (host opt-out)" do
      Smith.config.trace_adapter = Smith::Trace::Memory.new
      Smith.config.trace_normalizer = false
      profile = Smith::Models.find_or_infer("claude-opus-4-7")
      chat = build_chat
      chat.with_thinking(effort: "high")
      chat.with_temperature(1.0)

      described_class.apply!(chat, profile: profile)

      traced = Smith.config.trace_adapter.traces.select { |t| t[:type] == :normalizer_decision }
      expect(traced).to be_empty
    ensure
      Smith.config.trace_adapter = nil
      Smith.config.trace_normalizer = true
    end

    it "emits :thinking_dropped for models whose profile has no thinking shape (e.g., gpt-4.1)" do
      profile = Smith::Models.find_or_infer("gpt-4.1-mini")
      chat = build_chat(model: "gpt-4.1-mini")
      chat.with_thinking(effort: "high")

      decisions = described_class.apply!(chat, profile: profile)
      kinds = decisions.map(&:kind)
      expect(kinds).to include(:thinking_dropped)
      expect(chat.instance_variable_get(:@thinking)).to be_nil
    end

    it "emits :routed_via_responses when (gpt-5 family + tools + thinking) with openai_api_mode :auto" do
      original_mode = Smith.config.openai_api_mode
      Smith.config.openai_api_mode = :auto
      profile = Smith::Models.find_or_infer("gpt-5.5")
      chat = build_chat(model: "gpt-5.5")
      chat.with_thinking(effort: "high")
      chat.with_tools(Smith::Tools::Think)

      decisions = described_class.apply!(chat, profile: profile)
      kinds = decisions.map(&:kind)
      expect(kinds).to include(:routed_via_responses)
      expect(chat.instance_variable_get(:@params)).to include(openai_api_mode: :responses)
    ensure
      Smith.config.openai_api_mode = original_mode
    end

    it "emits :tool_dropped when an incompatible tool is removed (gpt-5 + tools + thinking with openai_api_mode :off)" do
      original_mode = Smith.config.openai_api_mode
      Smith.config.openai_api_mode = :off
      profile = Smith::Models.find_or_infer("gpt-5.5")
      chat = build_chat(model: "gpt-5.5")
      chat.with_thinking(effort: "high")
      chat.with_tools(Smith::Tools::Think)

      decisions = described_class.apply!(chat, profile: profile)
      kinds = decisions.map(&:kind)
      expect(kinds).to include(:tool_dropped)
      drop_detail = decisions.find { |d| d.kind == :tool_dropped }&.detail
      expect(drop_detail).to include(tool: "Smith::Tools::Think")
      expect(chat.tools).to be_empty
    ensure
      Smith.config.openai_api_mode = original_mode
    end
  end

  describe "End-to-end via Smith::Agent.chat (direct call path)" do
    # This is the canonical case that motivated placing the normalizer
    # in Smith::Agent.chat() rather than Lifecycle#attempt_model — direct
    # Agent.chat callers (like hadithi-xl's InvokeCleaner) need
    # normalization too.
    let(:agent_class) do
      Class.new(Smith::Agent) do
        model "claude-opus-4-7"
        temperature 1.0
        thinking effort: "xhigh"
      end
    end

    it "applies adaptive thinking translation on direct Agent.chat construction" do
      chat = agent_class.chat
      expect(chat.instance_variable_get(:@thinking)).to be_nil
      expect(chat.instance_variable_get(:@params)).to include(
        thinking: { type: "adaptive" },
        output_config: { effort: "xhigh" }
      )
      expect(chat.instance_variable_get(:@temperature)).to be_nil
    end
  end
end
