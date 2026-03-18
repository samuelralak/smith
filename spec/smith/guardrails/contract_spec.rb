# frozen_string_literal: true

RSpec.describe "Smith::Guardrails contract" do
  let(:guardrails_class) { require_const("Smith::Guardrails") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }

  it "provides the documented three-layer guardrail DSL" do
    %i[input tool output].each do |dsl|
      expect(guardrails_class).to respond_to(dsl), "expected Smith::Guardrails to implement .#{dsl}"
    end
  end

  it "allows declaring input, tool, and output checks in one guardrails class" do
    concrete = with_stubbed_class("SpecGuardrails", guardrails_class) do
      input :validate_schema
      tool :require_idempotency_key, on: [:mutate_graph]
      output :sanitize, max_string: 5000
    end

    expect(concrete).to be < guardrails_class
  end

  it "can be attached at both the agent and workflow levels" do
    concrete_guardrails = with_stubbed_class("SpecAttachedGuardrails", guardrails_class) do
      input :validate_schema
    end

    agent = with_stubbed_class("SpecGuardedAgent", agent_class) do
      guardrails concrete_guardrails
    end

    workflow = with_stubbed_class("SpecGuardedWorkflow", workflow_class) do
      guardrails concrete_guardrails
    end

    expect(agent).to be < agent_class
    expect(workflow).to be < workflow_class
  end

  it "retains distinct workflow-level and agent-level guardrail assignments when both exist" do
    workflow_guardrails = with_stubbed_class("SpecWorkflowLevelGuardrails", guardrails_class) do
      input :workflow_check
    end

    agent_guardrails = with_stubbed_class("SpecAgentLevelGuardrails", guardrails_class) do
      input :agent_check
    end

    agent = with_stubbed_class("SpecDualGuardedAgent", agent_class) do
      guardrails agent_guardrails
    end

    workflow = with_stubbed_class("SpecDualGuardedWorkflow", workflow_class) do
      guardrails workflow_guardrails
    end

    expect(agent.guardrails).to be(agent_guardrails)
    expect(workflow.guardrails).to be(workflow_guardrails)
  end

  it "runs workflow-level guardrails before agent-level guardrails during workflow execution" do
    observed = []

    workflow_guardrails = with_stubbed_class("SpecWorkflowRuntimeGuardrails", guardrails_class) do
      define_method(:workflow_input) { |_payload| observed << :workflow_input }
      define_method(:workflow_output) { |_payload| observed << :workflow_output }

      input :workflow_input
      output :workflow_output
    end

    agent_guardrails = with_stubbed_class("SpecAgentRuntimeGuardrails", guardrails_class) do
      define_method(:agent_input) { |_payload| observed << :agent_input }
      define_method(:agent_output) { |_payload| observed << :agent_output }

      input :agent_input
      output :agent_output
    end

    with_stubbed_class("SpecRuntimeGuardedAgent", agent_class) do
      guardrails agent_guardrails
      register_as :spec_runtime_guarded_agent
    end

    workflow = with_stubbed_class("SpecRuntimeGuardedWorkflow", workflow_class) do
      initial_state :idle
      state :done
      guardrails workflow_guardrails

      transition :start, from: :idle, to: :done do
        execute :spec_runtime_guarded_agent
      end
    end.new

    workflow.run!

    expect(observed).to eq(%i[workflow_input agent_input workflow_output agent_output])
  end
end
