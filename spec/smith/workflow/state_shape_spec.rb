# frozen_string_literal: true

require "json"

RSpec.describe "Smith::Workflow state serialization shape" do
  let(:workflow_class) { require_const("Smith::Workflow") }

  it "serializes to the documented state hash shape" do
    workflow = with_stubbed_class("SpecStateWorkflow", workflow_class) do
      initial_state :idle
    end.new(context: { branch_count: 6, metadata: { topic: "history" } })

    state = workflow.to_state

    expect(state.keys).to eq(%i[class state context budget_consumed step_count execution_namespace created_at updated_at])
    expect(state[:class]).to eq("SpecStateWorkflow")
    expect(state[:state]).to eq(:idle)
    expect(state[:context]).to eq(branch_count: 6, metadata: { topic: "history" })
    expect(state[:budget_consumed]).to be_a(Hash)
    expect(state[:step_count]).to be_a(Integer)
    expect(state[:created_at]).to be_a(String)
    expect(state[:updated_at]).to be_a(String)
  end

  it "round-trips through from_state without serializing agent instances" do
    workflow = with_stubbed_class("SpecRoundTripWorkflow", workflow_class) do
      initial_state :idle
    end.new(context: { branch_count: 3 })

    restored = workflow.class.from_state(workflow.to_state)

    expect(restored.to_state).to eq(workflow.to_state)
    expect(JSON.generate(restored.to_state)).to be_a(String)
  end

  it "preserves the execution namespace across serialization after workflow execution" do
    agent_class = require_const("Smith::Agent")

    agent = with_stubbed_class("SpecExecutionNamespaceAgent", agent_class) do
      register_as :spec_execution_namespace_agent
      model "gpt-5-mini"
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new("ok")
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow = with_stubbed_class("SpecExecutionNamespaceWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        execute :spec_execution_namespace_agent
      end
    end.new

    workflow.run!
    state = workflow.to_state
    restored = workflow.class.from_state(state)

    expect(state[:execution_namespace]).to be_a(String)
    expect(state[:execution_namespace]).not_to be_empty
    expect(restored.to_state[:execution_namespace]).to eq(state[:execution_namespace])
  end
end
