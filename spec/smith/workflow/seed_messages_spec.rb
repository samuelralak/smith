# frozen_string_literal: true

require "json"

RSpec.describe "Smith::Workflow seed_messages DSL" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:context_class) { require_const("Smith::Context") }

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
    expect(workflow.to_state[:seed_message_count]).to eq(1)
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

  it "normalizes JSON-restored message attribute keys at the RubyLLM boundary" do
    seen_messages = []
    agent = with_stubbed_class("SpecJsonRestoredMessagesAgent", agent_class) do
      register_as :spec_json_restored_messages_agent
      model "gpt-5-mini"
    end
    chat = Object.new
    chat.define_singleton_method(:add_message) do |attributes|
      seen_messages << RubyLLM::Message.new(attributes)
    end
    chat.define_singleton_method(:complete) { Struct.new(:content).new("accepted") }
    allow(agent).to receive(:chat).and_return(chat)

    klass = with_stubbed_class("SpecJsonRestoredMessagesWorkflow", workflow_class) do
      seed_messages do
        [{ "role" => "user", "content" => "Restored from durable JSON." }]
      end

      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { execute :spec_json_restored_messages_agent }
    end

    result = klass.new.run!

    expect(result.state).to eq(:done)
    expect(seen_messages.map(&:to_h)).to contain_exactly(
      include(role: :user, content: "Restored from durable JSON.")
    )
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
    expect(restored.to_state[:seed_message_count]).to eq(1)
    expect(restored.to_state[:session_messages].count { |message| message[:role].to_s == "user" }).to eq(1)
  end

  it "defaults legacy persisted state to no preserved seed prefix" do
    klass = with_stubbed_class("SpecLegacySeedCountWorkflow", workflow_class) do
      seed_messages { [{ role: :user, content: "legacy" }] }
      initial_state :idle
    end
    state = klass.new.to_state
    state.delete(:seed_message_count)

    restored = klass.from_state(state)

    expect(restored.to_state[:seed_message_count]).to eq(0)
  end

  it "applies the preserved seed prefix to observation masking after a persistence round trip" do
    manager = with_stubbed_class("SpecSeedMaskRestoreContext", context_class) do
      session_strategy :observation_masking, window: 1, preserve_seed: true
    end

    klass = with_stubbed_class("SpecSeedMaskRestoreWorkflow", workflow_class) do
      context_manager manager
      seed_messages do
        [
          { role: :user, content: "original request" },
          { role: :assistant, content: "prior answer" }
        ]
      end
      initial_state :idle
    end

    original = klass.new
    original.instance_variable_get(:@session_messages).push(
      { role: :assistant, content: "planner output" },
      { role: :assistant, content: "research output" }
    )

    restored = klass.from_state(JSON.parse(JSON.generate(original.to_state)))
    prepared = restored.send(:build_session).prepare!

    expect(prepared.map { _1[:content] || _1["content"] }).to eq(
      ["original request", "prior answer", "research output"]
    )
  end
end
