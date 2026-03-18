# frozen_string_literal: true

RSpec.describe "Smith::Tool failure policy contract" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:guardrails_class) { require_const("Smith::Guardrails") }
  let(:tool_class) { require_const("Smith::Tool") }
  let(:tool_guardrail_failed) { require_const("Smith::ToolGuardrailFailed") }
  let(:workflow_class) { require_const("Smith::Workflow") }

  it "raises ToolPolicyDenied when authorization fails" do
    tool = with_stubbed_class("SpecDeniedTool", tool_class) do
      category :action
      authorize { |_context| false }

      def perform(**kwargs)
        kwargs
      end
    end.new

    expect do
      tool.execute(context: { user: nil }, query: "test")
    end.to raise_error(require_const("Smith::ToolPolicyDenied"))
  end

  it "does not enforce approval metadata without a host hook" do
    tool = with_stubbed_class("SpecApprovalTool", tool_class) do
      category :action

      capabilities do
        approval :required
      end

      def perform(**kwargs)
        kwargs
      end
    end.new

    expect(tool.execute(context: { user: nil }, query: "test")).to include(query: "test")
  end

  it "allows a pre-dispatch hook to deny execution with ToolPolicyDenied" do
    policy_denied = require_const("Smith::ToolPolicyDenied")

    tool = with_stubbed_class("SpecHookDeniedTool", tool_class) do
      category :action

      capabilities do
        approval :required
      end

      before_execute do |_tool, _kwargs|
        raise policy_denied, "approval required"
      end

      def perform(**_kwargs)
        raise "perform should not run"
      end
    end.new

    expect do
      tool.execute(context: { user: :ok }, query: "test")
    end.to raise_error(policy_denied, "approval required")
  end

  it "raises ToolGuardrailFailed and blocks perform when an attached tool guardrail rejects the call" do
    observed_perform = []

    guarded_tool = with_stubbed_class("SpecGuardrailFailedTool", tool_class) do
      define_method(:perform) do |**_kwargs|
        observed_perform << :ran
        :ok
      end
    end

    workflow_guardrails = with_stubbed_class("SpecRejectingToolGuardrails", guardrails_class) do
      define_method(:reject_tool_call) do |_payload|
        raise "rate limit"
      end

      tool :reject_tool_call, on: [guarded_tool.new.name.to_sym]
    end

    with_stubbed_class("SpecToolGuardrailAgent", agent_class) do
      register_as :spec_tool_guardrail_agent
    end

    workflow = with_stubbed_class("SpecToolGuardrailWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed
      guardrails workflow_guardrails

      transition :start, from: :idle, to: :running do
        execute :spec_tool_guardrail_agent
        on_failure :fail
      end
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      guarded_tool.new.execute(context: @context, query: "test", prepared_input: prepared_input)
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(tool_guardrail_failed)
    expect(observed_perform).to eq([])
  end

  it "raises ToolGuardrailFailed when an agent-attached tool guardrail rejects the call" do
    guarded_tool = with_stubbed_class("SpecAgentGuardrailFailedTool", tool_class) do
      def perform(**_kwargs)
        raise "perform should not run"
      end
    end

    agent_guardrails = with_stubbed_class("SpecAgentRejectingToolGuardrails", guardrails_class) do
      define_method(:reject_tool_call) do |_payload|
        raise "malformed args"
      end

      tool :reject_tool_call, on: [guarded_tool.new.name.to_sym]
    end

    with_stubbed_class("SpecAgentAttachedToolGuardrailAgent", agent_class) do
      guardrails agent_guardrails
      register_as :spec_agent_attached_tool_guardrail_agent
    end

    workflow = with_stubbed_class("SpecAgentAttachedToolGuardrailWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed

      transition :start, from: :idle, to: :running do
        execute :spec_agent_attached_tool_guardrail_agent
        on_failure :fail
      end
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      guarded_tool.new.execute(context: @context, query: "test", prepared_input: prepared_input)
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(tool_guardrail_failed)
    expect(result.steps.first[:error]).not_to be_a(require_const("Smith::ToolPolicyDenied"))
  end
end
