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
end
