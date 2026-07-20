# frozen_string_literal: true

# Pins the direct-call normalization contract: when a host constructs a
# chat via `Smith::Agent.chat()` OUTSIDE the workflow lifecycle, the
# Smith::Models::Normalizer still fires on the
# returned chat. This is the reason Smith hooks the normalizer at
# Smith::Agent.chat() rather than at Lifecycle#attempt_model. The
# workflow-only hook point would miss every direct caller.

RSpec.describe "Smith::Agent.chat() direct-call normalization" do
  before(:each) do
    RubyLLM.configure do |c|
      c.anthropic_api_key = "test-anthropic-key"
      c.openai_api_key    = "test-openai-key"
      c.gemini_api_key    = "test-gemini-key"
    end
  end

  it "scopes tool execution on Smith-created chats without changing raw RubyLLM chats" do
    tool_class = Class.new(Smith::Tool) do
      def perform(**_kwargs) = :ok
    end
    agent_class = Class.new(Smith::Agent) do
      model "gpt-5-mini"
      tools tool_class
    end

    smith_chat = agent_class.chat
    raw_chat = RubyLLM.chat(model: "gpt-5-mini")

    expect(smith_chat.singleton_class).to be < Smith::Tool::ChatExecutionContext
    expect(raw_chat.singleton_class).not_to be < Smith::Tool::ChatExecutionContext
  end

  describe "Opus 4.7 (adaptive thinking, no temperature)" do
    let(:agent_class) do
      Class.new(Smith::Agent) do
        register_as :direct_chat_opus_writer
        model "claude-opus-4-7"
        temperature 1.0
        thinking effort: "high"
      end
    end

    it "translates @thinking to params[:thinking] = { type: :adaptive } + output_config" do
      chat = agent_class.chat

      expect(chat.instance_variable_get(:@thinking)).to be_nil
      expect(chat.instance_variable_get(:@params)).to include(
        thinking: { type: "adaptive" },
        output_config: { effort: "high" }
      )
    end

    it "nulls @temperature on the same direct chat" do
      chat = agent_class.chat
      expect(chat.instance_variable_get(:@temperature)).to be_nil
    end

    it "preserves the resolved chat after add_message in direct-call flows" do
      # Mirrors a direct caller that builds the chat, appends a user
      # message, then calls .complete. Normalization fires at chat
      # construction; downstream add_message must NOT undo the adaptive
      # translation already stamped into @params.
      chat = agent_class.chat
      chat.add_message(role: :user, content: "Clean this draft.")

      expect(chat.messages.size).to eq(1)
      expect(chat.instance_variable_get(:@params)[:thinking]).to eq(type: "adaptive")
      expect(chat.instance_variable_get(:@temperature)).to be_nil
    end
  end

  describe "explicit model: kwarg path" do
    let(:agent_class) do
      Class.new(Smith::Agent) do
        register_as :direct_chat_explicit_writer
        model "claude-opus-4-7"
        temperature 1.0
        thinking effort: "high"
      end
    end

    it "uses the explicit kwarg's model_id over the class-level chat_kwargs[:model]" do
      # Lifecycle#attempt_model passes `model:` explicitly per attempt.
      # Direct callers can do the same when they need a one-off override.
      chat = agent_class.chat(model: "gpt-5.5")

      # gpt-5.5 profile is OpenAI gpt-5 family: thinking_shape :reasoning_effort
      # (preserved), accepts_temperature false (nulled).
      expect(chat.instance_variable_get(:@temperature)).to be_nil
      expect(chat.instance_variable_get(:@thinking)).not_to be_nil
      expect(chat.instance_variable_get(:@thinking).effort).to eq("high")
    end
  end

  describe "Gemini 2.5 (budget_tokens thinking, accepts temperature)" do
    let(:agent_class) do
      Class.new(Smith::Agent) do
        register_as :direct_chat_gemini_writer
        model "gemini-2.5-pro"
        temperature 1.0
        thinking effort: "high"
      end
    end

    it "preserves @thinking and @temperature for budget_tokens-shaped providers" do
      chat = agent_class.chat

      # Gemini 2.5+ rule: thinking_shape :budget_tokens (preserved by
      # provider renderer), accepts_temperature: true (preserved).
      expect(chat.instance_variable_get(:@thinking)).not_to be_nil
      expect(chat.instance_variable_get(:@temperature)).to eq(1.0)
    end
  end

  describe "agent with no model declared" do
    let(:agent_class) do
      Class.new(Smith::Agent) do
        register_as :direct_chat_no_model
      end
    end

    it "skips normalization when no model_id is resolvable (no-op profile path)" do
      # When `model_id || chat_kwargs[:model]` is nil, resolve_profile
      # returns nil and Normalizer.apply! is skipped. Verifies the
      # graceful no-op for static-typed agents that defer model
      # selection to a later layer.
      chat = agent_class.chat(model: nil)
      # No exception raised; chat is a usable RubyLLM::Chat object.
      expect(chat).to respond_to(:add_message)
    end
  end

  describe "trace emission on direct chat" do
    let(:agent_class) do
      Class.new(Smith::Agent) do
        register_as :direct_chat_traced_writer
        model "claude-opus-4-7"
        temperature 1.0
        thinking effort: "high"
      end
    end

    it "emits :normalizer_decision trace events from direct chat construction" do
      events = []
      allow(Smith::Trace).to receive(:record) { |**args| events << args }

      agent_class.chat

      kinds = events.select { |e| e[:type] == :normalizer_decision }.map { |e| e[:data][:kind] }
      expect(kinds).to include(:thinking_translated_to_adaptive, :temperature_dropped)
    end
  end
end
