# frozen_string_literal: true

RSpec.describe "Smith::Workflow seed_messages DSL" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }

  it "seeds session history for newly initialized workflows" do
    klass = with_stubbed_class("SpecSeedMessagesWorkflow", workflow_class) do
      seed_messages do |ctx|
        [{ role: :user, content: "Research: #{ctx[:topic]}" }]
      end

      initial_state :idle
    end

    workflow = klass.new(context: { topic: "African trade" })

    expect(workflow.to_state[:session_messages]).to eq(
      [{ role: :user, content: "Research: African trade" }]
    )
  end

  it "passes seeded session messages to agent execution even without a context manager" do
    seen_messages = []

    agent = with_stubbed_class("SpecSeedMessagesExecutionAgent", agent_class) do
      register_as :spec_seed_messages_execution_agent
      model "gpt-5-mini"
    end

    chat = Object.new
    chat.define_singleton_method(:add_message) do |message|
      seen_messages << message
    end
    chat.define_singleton_method(:complete) { Struct.new(:content).new("accepted") }

    allow(agent).to receive(:chat).and_return(chat)

    klass = with_stubbed_class("SpecSeedMessagesExecutionWorkflow", workflow_class) do
      seed_messages do |ctx|
        [{ role: :user, content: "Research: #{ctx[:topic]}" }]
      end

      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        execute :spec_seed_messages_execution_agent
      end
    end

    result = klass.new(context: { topic: "ports" }).run!

    expect(result.state).to eq(:done)
    expect(seen_messages).to eq([{ role: :user, content: "Research: ports" }])
  end

  it "does not rerun seed_messages after restoring persisted state" do
    agent = with_stubbed_class("SpecSeedMessagesAgent", agent_class) do
      register_as :spec_seed_messages_agent
      model "gpt-5-mini"
    end

    chat = Object.new
    chat.define_singleton_method(:add_message) { |_message| nil }
    chat.define_singleton_method(:complete) { Struct.new(:content).new("accepted") }

    allow(agent).to receive(:chat).and_return(chat)

    klass = with_stubbed_class("SpecSeedMessagesRestoreWorkflow", workflow_class) do
      seed_messages do |ctx|
        [{ role: :user, content: "Prompt: #{ctx[:topic]}" }]
      end

      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        execute :spec_seed_messages_agent
      end
    end

    workflow = klass.new(context: { topic: "payments" })
    workflow.run!

    restored = klass.from_state(workflow.to_state)

    expect(restored.to_state[:session_messages]).to eq(workflow.to_state[:session_messages])
    expect(restored.to_state[:session_messages].count { |message| message[:role].to_s == "user" }).to eq(1)
  end
end
