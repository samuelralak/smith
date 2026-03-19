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
end
