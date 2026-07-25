# frozen_string_literal: true

RSpec.describe "Smith::Agent persisted chat execution context" do
  def runtime_chat
    Class.new do
      attr_reader :tools

      def initialize
        @tools = {}
      end

      private

      def execute_tool(_tool_call) = nil
    end.new
  end

  def persisted_record(chat)
    Object.new.tap do |record|
      record.define_singleton_method(:to_llm) { chat }
    end
  end

  it "installs the execution boundary on create and create! results" do
    agent = Class.new(Smith::Agent)
    chats = [runtime_chat, runtime_chat]
    records = chats.map { persisted_record(_1) }
    allow(agent).to receive(:with_rails_chat_record).and_return(*records)

    expect(agent.create).to equal(records.first)
    expect(agent.create!).to equal(records.last)
    expect(chats).to all(satisfy { |chat| chat.singleton_class < Smith::Tool::ChatExecutionContext })
  end

  it "installs the execution boundary on find results" do
    agent = Class.new(Smith::Agent)
    chat = runtime_chat
    record = persisted_record(chat)
    model = class_double("PersistedChatModel", find: record)
    allow(agent).to receive(:resolved_chat_model).and_return(model)
    allow(agent).to receive(:partition_inputs).and_return([{}, {}])
    allow(agent).to receive(:apply_configuration)

    expect(agent.find("chat-1")).to equal(record)
    expect(chat.singleton_class).to be < Smith::Tool::ChatExecutionContext
  end

  it "preserves real RubyLLM Active Record chat behavior", :ar do
    previous_api_key = RubyLLM.config.openai_api_key
    RubyLLM.config.openai_api_key = "offline-persistence-proof"
    tool = stub_const("SpecPersistedContextTool", Class.new(Smith::Tool) do
      description "Returns a context marker"
      def perform = self.class.current_invocation_context
    end)
    agent = stub_const("SpecPersistedContextAgent", Class.new(Smith::Agent) do
      chat_model SpecRubyLLMChat
      model "gpt-4.1-mini", provider: :openai, assume_model_exists: true
      instructions "Use the persisted conversation."
      tools SpecPersistedContextTool
    end)

    created = agent.create
    created_bang = agent.create!
    created_chat = created.to_llm
    created_bang_chat = created_bang.to_llm

    expect([created, created_bang]).to all(be_persisted)
    expect([created.messages.count, created_bang.messages.count]).to eq([1, 1])
    expect([created_chat, created_bang_chat]).to all(
      satisfy { |chat| chat.singleton_class < Smith::Tool::ChatExecutionContext }
    )
    expect([created_chat, created_bang_chat]).to all(
      satisfy { |chat| chat.tools.values.any?(tool) }
    )

    persisted_message_count = created.messages.count
    found = agent.find(created.id)
    found_chat = found.to_llm

    expect(found_chat.singleton_class).to be < Smith::Tool::ChatExecutionContext
    expect(found_chat).to equal(found.to_llm)
    expect(found_chat.tools.values.any?(tool)).to be(true)
    expect(found_chat.messages.length).to eq(1)
    expect(created.messages.reload.count).to eq(persisted_message_count)
  ensure
    RubyLLM.config.openai_api_key = previous_api_key
  end

  it "normalizes endpoint-compatible tools for persisted chats", :ar do
    previous_api_key = RubyLLM.config.openai_api_key
    previous_openai_api_mode = Smith.config.openai_api_mode
    RubyLLM.config.openai_api_key = "offline-persistence-proof"
    Smith.config.openai_api_mode = :auto
    tool = stub_const("SpecPersistedResponsesTool", Class.new(Smith::Tool) do
      compatible_with openai: :responses
      def perform(query:) = query
    end)
    agent = stub_const("SpecPersistedNormalizedAgent", Class.new(Smith::Agent) do
      chat_model SpecRubyLLMChat
      model "o3", provider: :openai, assume_model_exists: true
      tools SpecPersistedResponsesTool
    end)

    created = agent.create
    created_bang = agent.create!
    found = agent.find(created.id)

    [created, created_bang, found].each do |record|
      chat = record.to_llm
      expect(chat.instance_variable_get(:@params)).to include(openai_api_mode: :responses)
      expect(chat.tools.values.map(&:class)).to include(tool)
    end
  ensure
    RubyLLM.config.openai_api_key = previous_api_key
    Smith.config.openai_api_mode = previous_openai_api_mode
  end

  it "injects reserved Smith inputs before persisted dynamic configuration is evaluated", :ar do
    previous_api_key = RubyLLM.config.openai_api_key
    RubyLLM.config.openai_api_key = "offline-persistence-proof"
    captured = []
    tool = stub_const("SpecPersistedDynamicInputTool", Class.new(Smith::Tool) do
      def perform = :ok
    end)
    agent = stub_const("SpecPersistedDynamicInputAgent", Class.new(Smith::Agent) do
      chat_model SpecRubyLLMChat
      model "gpt-4.1-mini", provider: :openai, assume_model_exists: true
      tools do |context|
        captured << {
          model_id: context.model_id,
          provider: context.provider,
          endpoint_mode: context.endpoint_mode
        }
        [tool]
      end
    end)

    created = agent.create
    agent.model "claude-sonnet-4-6", provider: :anthropic, assume_model_exists: true
    found = agent.find(created.id)

    expect(created.to_llm.tools.values.map(&:class)).to contain_exactly(tool)
    expect(found.to_llm.tools.values.map(&:class)).to contain_exactly(tool)
    expect(captured).to all(eq(model_id: "gpt-4.1-mini", provider: :openai, endpoint_mode: :chat_completions))
  ensure
    RubyLLM.config.openai_api_key = previous_api_key
  end
end
