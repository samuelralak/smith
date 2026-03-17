# frozen_string_literal: true

RSpec.describe "Smith::Workflow serialization contract" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:persistence_namespace) { require_const("Smith::Workflow::Persistence") }

  it "defines the persistence helper namespace used by host applications" do
    expect(persistence_namespace).not_to be_nil
  end

  it "serializes through to_state and restores through from_state" do
    workflow = workflow_class.allocate

    expect(workflow).to respond_to(:to_state)
    expect(workflow_class).to respond_to(:from_state)
  end
end
