# frozen_string_literal: true

RSpec.describe "Smith::Workflow heterogeneous fan-out" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:context_class) { require_const("Smith::Context") }
  let(:guardrails_class) { require_const("Smith::Guardrails") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:workflow_error) { require_const("Smith::WorkflowError") }

  let!(:static_agent) do
    with_stubbed_class("SpecFanoutStaticAgent", agent_class) do
      register_as :spec_fanout_static_agent
    end
  end

  let!(:security_agent) do
    with_stubbed_class("SpecFanoutSecurityAgent", agent_class) do
      register_as :spec_fanout_security_agent
    end
  end

  it "declares a fan_out transition with stable branch keys" do
    workflow = with_stubbed_class("SpecFanoutContractWorkflow", workflow_class) do
      initial_state :idle
      state :reviewed

      transition :review, from: :idle, to: :reviewed do
        fan_out branches: {
          static: :spec_fanout_static_agent,
          security: :spec_fanout_security_agent
        }
      end
    end

    transition = workflow.find_transition(:review)

    expect(transition.fanout?).to be true
    expect(transition.fanout_config.fetch(:branches)).to eq(
      static: :spec_fanout_static_agent,
      security: :spec_fanout_security_agent
    )
  end

  it "rejects fan_out mixed with another execution primitive" do
    expect do
      with_stubbed_class("SpecFanoutExecuteConflictWorkflow", workflow_class) do
        initial_state :idle
        state :reviewed

        transition :review, from: :idle, to: :reviewed do
          execute :spec_fanout_static_agent
          fan_out branches: { security: :spec_fanout_security_agent }
        end
      end
    end.to raise_error(workflow_error, /fan_out and execute/)
  end

  it "validates branch declarations before runtime" do
    expect do
      with_stubbed_class("SpecFanoutBlankBranchWorkflow", workflow_class) do
        initial_state :idle
        state :reviewed

        transition :review, from: :idle, to: :reviewed do
          fan_out branches: { " " => :spec_fanout_security_agent }
        end
      end
    end.to raise_error(workflow_error, /branch keys/)

    expect do
      with_stubbed_class("SpecFanoutBlankAgentWorkflow", workflow_class) do
        initial_state :idle
        state :reviewed

        transition :review, from: :idle, to: :reviewed do
          fan_out branches: { security: " " }
        end
      end
    end.to raise_error(workflow_error, /must declare an agent/)
  end

  it "rejects duplicate branch agent declarations" do
    expect do
      with_stubbed_class("SpecFanoutDuplicateAgentWorkflow", workflow_class) do
        initial_state :idle
        state :reviewed

        transition :review, from: :idle, to: :reviewed do
          fan_out branches: {
            static: :spec_fanout_static_agent,
            duplicate: :spec_fanout_static_agent
          }
        end
      end
    end.to raise_error(workflow_error, /distinct/)
  end

  it "returns one named branch result per declared agent" do
    workflow = with_stubbed_class("SpecFanoutRuntimeWorkflow", workflow_class) do
      initial_state :idle
      state :reviewed

      transition :review, from: :idle, to: :reviewed do
        fan_out branches: {
          static: :spec_fanout_static_agent,
          security: :spec_fanout_security_agent
        }
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:reviewed)
    expect(result.output).to eq(
      [
        { branch: :static, agent: :spec_fanout_static_agent, output: nil },
        { branch: :security, agent: :spec_fanout_security_agent, output: nil }
      ]
    )
  end

  it "routes through on_failure when any branch fails" do
    workflow = with_stubbed_class("SpecFanoutFailureWorkflow", workflow_class) do
      initial_state :idle
      state :reviewed
      state :failed

      transition :review, from: :idle, to: :reviewed do
        fan_out branches: {
          static: :spec_fanout_static_agent,
          security: :spec_fanout_security_agent
        }
        on_failure :fail
      end
    end.new

    workflow.define_singleton_method(:guarded_fanout_branch_call) do |_agent_class, _env, _signal|
      @fanout_calls ||= 0
      @fanout_calls += 1
      raise Smith::WorkflowError, "branch failed" if @fanout_calls == 1

      :ok
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.output).to be_nil
    expect(result.steps.first[:transition]).to eq(:review)
    expect(result.steps.first[:error]).to be_a(workflow_error)
  end

  it "surfaces the initiating branch error ahead of cooperative cancellation" do
    workflow = with_stubbed_class("SpecFanoutCancellationCauseWorkflow", workflow_class) do
      initial_state :idle
      state :reviewed
      state :failed

      transition :review, from: :idle, to: :reviewed do
        fan_out branches: {
          static: :spec_fanout_static_agent,
          security: :spec_fanout_security_agent
        }
        on_failure :fail
      end
    end.new

    workflow.define_singleton_method(:guarded_fanout_branch_call) do |agent_class, _env, signal|
      raise Smith::AgentError, "security branch failed" unless agent_class.register_as == :spec_fanout_static_agent

      sleep 0.05
      check_cancellation!(signal)
      :static
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(Smith::AgentError)
    expect(result.steps.first[:error].message).to eq("security branch failed")
  end

  it "applies workflow guardrails once and agent guardrails per branch" do
    observed = Queue.new

    workflow_guardrails = with_stubbed_class("SpecFanoutWorkflowGuardrails", guardrails_class) do
      define_method(:input_once) { |context| observed << [:workflow_input, context] }
      define_method(:output_once) { |output| observed << [:workflow_output, output] }

      input :input_once
      output :output_once
    end

    agent_guardrails = with_stubbed_class("SpecFanoutAgentGuardrails", guardrails_class) do
      define_method(:input_per_branch) { |context| observed << [:agent_input, context] }
      define_method(:output_per_branch) { |output| observed << [:agent_output, output] }

      input :input_per_branch
      output :output_per_branch
    end

    [static_agent, security_agent].each { |klass| klass.guardrails agent_guardrails }

    workflow = with_stubbed_class("SpecFanoutGuardrailWorkflow", workflow_class) do
      initial_state :idle
      state :reviewed
      guardrails workflow_guardrails

      transition :review, from: :idle, to: :reviewed do
        fan_out branches: {
          static: :spec_fanout_static_agent,
          security: :spec_fanout_security_agent
        }
      end
    end.new(context: { ticket_id: "T-1" })

    result = workflow.run!

    expect(result.state).to eq(:reviewed)
    events = []
    events << observed.pop until observed.empty?

    expect(events.count { |event, _| event == :workflow_input }).to eq(1)
    expect(events.count { |event, _| event == :workflow_output }).to eq(1)
    expect(events.count { |event, _| event == :agent_input }).to eq(2)
    expect(events.count { |event, _| event == :agent_output }).to eq(2)
  end

  it "runs branch input guardrails before preparing session state" do
    rejecting_guardrails = with_stubbed_class("SpecFanoutRejectingGuardrails", guardrails_class) do
      define_method(:reject_input) { |_context| raise "blocked before prepare" }

      input :reject_input
    end

    with_stubbed_class("SpecFanoutRejectedAgent", agent_class) do
      register_as :spec_fanout_rejected_agent
      guardrails rejecting_guardrails
    end

    with_stubbed_class("SpecFanoutAllowedAgent", agent_class) do
      register_as :spec_fanout_allowed_agent
    end

    context_manager = with_stubbed_class("SpecFanoutGuardedSessionContext", context_class) do
      persist :current_findings
      inject_state { |persisted| "summary: #{persisted[:current_findings]}" }
    end

    workflow = with_stubbed_class("SpecFanoutGuardedSessionWorkflow", workflow_class) do
      context_manager context_manager
      initial_state :idle
      state :reviewed
      state :failed

      transition :review, from: :idle, to: :reviewed do
        fan_out branches: {
          blocked: :spec_fanout_rejected_agent,
          allowed: :spec_fanout_allowed_agent
        }
        on_failure :fail
      end
    end.new(context: { current_findings: "stable" })

    workflow.instance_variable_set(:@session_messages, [{ role: :user, content: "latest" }])

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(Smith::GuardrailFailed)
    expect(workflow.session_messages).to eq([{ role: :user, content: "latest" }])
  end

  it "exposes fanout metadata through graph inspection" do
    workflow = with_stubbed_class("SpecFanoutGraphWorkflow", workflow_class) do
      initial_state :idle
      state :reviewed

      transition :review, from: :idle, to: :reviewed do
        fan_out branches: {
          static: :spec_fanout_static_agent,
          security: :spec_fanout_security_agent
        }
      end
    end

    transition = workflow.validate_graph.transitions.find { |snapshot| snapshot.name == :review }

    expect(transition.kind).to eq(:fanout)
    expect(transition.to_h.fetch(:fanout_branches)).to eq(
      static: :spec_fanout_static_agent,
      security: :spec_fanout_security_agent
    )
  end
end
