# frozen_string_literal: true

RSpec.describe "Smith::Workflow contract" do
  let(:workflow_class) { require_const("Smith::Workflow") }

  it "exposes the workflow DSL used throughout the architecture" do
    %i[initial_state state transition budget max_transitions guardrails context_manager].each do |dsl|
      expect(workflow_class).to respond_to(dsl), "expected Smith::Workflow to implement .#{dsl}"
    end
  end

  it "supports stepwise execution, full-run execution, and serialization hooks" do
    workflow = workflow_class.allocate

    expect(workflow).to respond_to(:advance!)
    expect(workflow).to respond_to(:run!)
    expect(workflow).to respond_to(:state)
    expect(workflow).to respond_to(:to_state)
    expect(workflow_class).to respond_to(:from_state)
  end

  it "supports the documented transition DSL shape" do
    klass = with_stubbed_class("SpecWorkflow", workflow_class) do
      initial_state :idle
      state :ready
      state :failed
      budget total_cost: 2.0, wall_clock: 600
      max_transitions 30

      transition :start, from: :idle, to: :ready do
        execute :spec_research_agent
        on_success :finish
        on_failure :fail
      end
    end

    expect(klass).to be < workflow_class
  end
end
