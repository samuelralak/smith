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
end
