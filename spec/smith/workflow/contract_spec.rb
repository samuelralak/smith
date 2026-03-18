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

  it "stores the documented transition metadata for execute, on_success, and on_failure" do
    klass = with_stubbed_class("SpecTransitionMetadataWorkflow", workflow_class) do
      initial_state :idle
      state :ready

      transition :start, from: :idle, to: :ready do
        execute :spec_research_agent, schema: :result_schema
        on_success :finish
        on_failure :fail
      end
    end

    transition = klass.instance_variable_get(:@transitions).fetch(:start)

    expect(transition.name).to eq(:start)
    expect(transition.from).to eq(:idle)
    expect(transition.to).to eq(:ready)
    expect(transition.agent_name).to eq(:spec_research_agent)
    expect(transition.agent_opts).to eq(schema: :result_schema)
    expect(transition.success_transition).to eq(:finish)
    expect(transition.failure_transition).to eq(:fail)
  end

  it "auto-generates a default fail transition when a failed state exists" do
    klass = with_stubbed_class("SpecAutoFailWorkflow", workflow_class) do
      initial_state :idle
      state :processing
      state :failed

      transition :start, from: :idle, to: :processing do
        execute :spec_research_agent
        on_failure :fail
      end
    end

    transitions = klass.instance_variable_get(:@transitions)

    expect(transitions).to include(:fail)

    fail_transition = transitions.fetch(:fail)
    expect(fail_transition.name).to eq(:fail)
    expect(fail_transition.to).to eq(:failed)
  end

  it "allows an explicit fail transition to override the auto-generated default" do
    klass = with_stubbed_class("SpecExplicitFailWorkflow", workflow_class) do
      initial_state :idle
      state :processing
      state :failed

      transition :fail, from: :processing, to: :failed do
        execute :failure_agent, mode: :cleanup
      end
    end

    fail_transition = klass.instance_variable_get(:@transitions).fetch(:fail)

    expect(fail_transition.from).to eq(:processing)
    expect(fail_transition.to).to eq(:failed)
    expect(fail_transition.agent_name).to eq(:failure_agent)
    expect(fail_transition.agent_opts).to eq(mode: :cleanup)
  end
end
