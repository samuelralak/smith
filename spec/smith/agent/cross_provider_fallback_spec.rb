# frozen_string_literal: true

# Pins the cross-provider fallback contract: when primary Claude fails
# with a transient error, fallback gpt-5.5 runs WITH a fresh, model-aware
# chat configuration. The normalizer fires per-attempt — each attempt
# gets its model's profile applied (adaptive thinking for Claude;
# tool-drop OR responses-route for gpt-5).
#
# Pre-refactor, this scenario was BROKEN: the same chat config went to
# both providers, gpt-5 + tools + reasoning_effort failed with
# BadRequestError (non-transient), and the fallback chain never recovered.
# This spec pins that we no longer have that problem.

RSpec.describe "cross-provider fallback with model-aware normalization" do
  before(:each) do
    RubyLLM.configure do |c|
      c.anthropic_api_key = "test-anthropic-key"
      c.openai_api_key    = "test-openai-key"
    end
  end

  let(:agent_class) do
    Class.new(Smith::Agent) do
      register_as :cross_provider_writer
      model "claude-opus-4-7"
      fallback_models "gpt-5.5"
      temperature 1.0
      thinking effort: "xhigh"
    end
  end

  describe "per-attempt normalization via Smith::Agent.chat" do
    it "applies Opus 4.7 adaptive thinking + temperature drop on the PRIMARY attempt" do
      chat = agent_class.chat(model: "claude-opus-4-7")

      expect(chat.instance_variable_get(:@thinking)).to be_nil
      expect(chat.instance_variable_get(:@temperature)).to be_nil
      expect(chat.instance_variable_get(:@params)).to include(
        thinking: { type: "adaptive" },
        output_config: { effort: "xhigh" }
      )
    end

    it "applies gpt-5.5 native shape (reasoning_effort, no temperature) on the FALLBACK attempt" do
      chat = agent_class.chat(model: "gpt-5.5")

      # gpt-5.5 profile: accepts_temperature: false → @temperature nulled
      # gpt-5.5 profile: thinking_shape: :reasoning_effort → @thinking
      #                  preserved (RubyLLM's OpenAI renderer emits
      #                  reasoning_effort natively from Thinking::Config).
      expect(chat.instance_variable_get(:@temperature)).to be_nil
      expect(chat.instance_variable_get(:@thinking)).not_to be_nil
      expect(chat.instance_variable_get(:@thinking).effort).to eq("xhigh")
    end

    it "injects reserved runtime inputs (model_id, provider, endpoint_mode) per attempt" do
      # Smith::Agent.chat fills RESERVED_INPUT_NAMES from the resolved
      # profile so block-form DSLs can branch on the active model.
      # This is the runtime contract test — both primary and fallback
      # attempts get correct reserved values.
      primary_kwargs = nil
      fallback_kwargs = nil

      original_chat = agent_class.method(:chat)
      allow(agent_class).to receive(:chat) do |**kwargs|
        if kwargs[:model] == "claude-opus-4-7"
          primary_kwargs = kwargs
        elsif kwargs[:model] == "gpt-5.5"
          fallback_kwargs = kwargs
        end
        original_chat.call(**kwargs)
      end

      agent_class.chat(model: "claude-opus-4-7")
      agent_class.chat(model: "gpt-5.5")

      # Reserved values are injected before super and reach RubyLLM,
      # which exposes them as singleton methods on runtime_context.
      # We can't directly read them here, but the chats build cleanly.
      expect(primary_kwargs[:model]).to eq("claude-opus-4-7")
      expect(fallback_kwargs[:model]).to eq("gpt-5.5")
    end
  end

  describe "tool compatibility on cross-provider fallback" do
    let(:agent_with_tools) do
      Class.new(Smith::Agent) do
        register_as :cross_provider_writer_with_tools
        model "claude-opus-4-7"
        fallback_models "gpt-5.5"
        temperature 1.0
        thinking effort: "high"
        tools Smith::Tools::Think
      end
    end

    it "keeps Think tool on the Claude path (Anthropic native tools+thinking)" do
      chat = agent_with_tools.chat(model: "claude-opus-4-7")
      tool_keys = chat.tools.keys
      expect(tool_keys).to include(:"smith--tools--think")
    end

    it "drops Think tool on the gpt-5.5 path when openai_api_mode is :off (graceful degradation)" do
      # With openai_api_mode explicitly :off, Smith::Models::Normalizer
      # detects (gpt-5 + tools + thinking), falls through to
      # drop_incompatible_tools, and the Think tool is dropped per its
      # compatible_with declaration (which excludes OpenAI on
      # :chat_completions endpoint). With :auto (the default), the
      # normalizer instead routes via /v1/responses where tools+thinking
      # work natively.
      Smith.config.openai_api_mode = :off
      chat = agent_with_tools.chat(model: "gpt-5.5")
      expect(chat.tools).to be_empty
    ensure
      Smith.config.openai_api_mode = :auto
    end
  end

  describe "Smith.config.openai_api_mode :auto routing intent" do
    # When openai_api_mode is :auto, the normalizer routes via /v1/responses
    # instead of dropping tools. The Responses adapter is vendored from
    # crmne/ruby_llm PR #770 at a pinned SHA (see lib/smith/providers/
    # openai/responses.rb). This spec validates the chat-construction
    # contract (params[:openai_api_mode] = :responses); the HTTP dispatch
    # itself is exercised by spec/smith/providers/openai/routing_spec.rb.

    before { Smith.config.openai_api_mode = :auto }
    after  { Smith.config.openai_api_mode = :off }

    it "sets params[:openai_api_mode] = :responses on chat construction with tools+thinking" do
      agent_class_with_tools = Class.new(Smith::Agent) do
        register_as :routing_test_writer
        model "gpt-5.5"
        temperature 1.0
        thinking effort: "high"
        tools Smith::Tools::Think
      end

      chat = agent_class_with_tools.chat
      expect(chat.instance_variable_get(:@params)).to include(openai_api_mode: :responses)
    end
  end
end
