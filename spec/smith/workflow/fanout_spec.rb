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

  it "revalidates fan-out size before resolving runtime bindings" do
    original_limit = Smith.config.parallel_branch_limit
    Smith.config.parallel_branch_limit = 2
    workflow = Class.new(workflow_class) do
      initial_state :idle
      state :reviewed
      transition :review, from: :idle, to: :reviewed do
        fan_out branches: { first: :missing_first_agent, second: :missing_second_agent }
      end
    end.new

    Smith.config.parallel_branch_limit = 1

    expect { workflow.run! }.to raise_error(workflow_error, /exceeds configured limit 1/)
  ensure
    Smith.config.parallel_branch_limit = original_limit
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

  it "preserves ordinary workflow fanout extension points" do
    calls = Queue.new
    base = Class.new(workflow_class) do
      initial_state :idle
      state :reviewed
      transition :review, from: :idle, to: :reviewed do
        fan_out branches: {
          static: :spec_fanout_static_agent,
          security: :spec_fanout_security_agent
        }
      end
    end
    workflow = Class.new(base) do
      define_method(:run_fanout_branch) do |*arguments|
        calls << :called
        super(*arguments)
      end
      private :run_fanout_branch
    end.new

    expect(workflow.run!.state).to eq(:reviewed)
    expect(calls.size).to eq(2)
  end

  it "preserves bindings installed by fanout setup extensions" do
    marker = Object.new
    observed = Queue.new
    base = Class.new(workflow_class) do
      initial_state :idle
      state :done
      transition :review, from: :idle, to: :done do
        fan_out branches: { static: :spec_fanout_static_agent }
      end
    end
    extended = Class.new(base) do
      define_method(:setup_fanout_branch_context) do |environment, ledger, agent|
        super(environment, ledger, agent)
        Thread.current[:smith_parallel_agent_binding] = marker
      end

      define_method(:guarded_fanout_branch_call) do |*arguments|
        observed << Thread.current[:smith_parallel_agent_binding]
        super(*arguments)
      end

      private :setup_fanout_branch_context, :guarded_fanout_branch_call
    end

    expect(extended.new.run!).to be_done
    expect(observed.pop).to equal(marker)
  end

  it "restores complete branch context across nested parallel and fan-out workflows" do
    capture = lambda do
      {
        guardrails: Smith::Tool.current_guardrails,
        deadline: Smith::Tool.current_deadline,
        ledger: Smith::Tool.current_ledger,
        allowance: Smith::Tool.current_tool_call_allowance,
        collector: Smith::Tool.current_tool_result_collector,
        artifacts: Smith.scoped_artifacts,
        call_deadline: Thread.current[:smith_call_deadline],
        call_ledger: Thread.current[:smith_call_ledger],
        failed_results: Thread.current[:smith_failed_agent_results],
        last_result: Thread.current[:smith_last_agent_result],
        parallel_binding: Thread.current[:smith_parallel_agent_binding]
      }
    end
    inner_parallel = Class.new(workflow_class) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done do
        execute :spec_fanout_static_agent, parallel: true, count: 1
      end
    end
    inner_fanout = Class.new(workflow_class) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done do
        fan_out branches: {
          static: :spec_fanout_static_agent,
          security: :spec_fanout_security_agent
        }
      end
    end

    [inner_parallel, inner_fanout].each do |inner|
      observations = Queue.new
      outer = Class.new(workflow_class) do
        initial_state :idle
        state :done
        transition :finish, from: :idle, to: :done do
          fan_out branches: {
            static: :spec_fanout_static_agent,
            security: :spec_fanout_security_agent
          }
        end
      end.new
      outer.define_singleton_method(:guarded_fanout_branch_call) do |_agent_class, env, signal|
        check_cancellation!(signal)
        before = capture.call
        inner.new.run!
        observations << [before, capture.call]
        check_cancellation!(signal)
        env.prepared_input
      end

      expect(outer.run!.state).to eq(:done)
      2.times do
        before, after = observations.pop
        expect(after).to eq(before)
      end
    end
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
    expect(transition.to_h.fetch(:fanout)).to eq(
      branch_count: 2,
      join_state: :reviewed,
      output_shape: :named_branch_results,
      branch_order: :declaration_order,
      join: {
        state: :reviewed,
        transition: :review
      },
      output_contract: {
        collection: :array,
        item_shape: :named_branch_result,
        ordering: :branch_declaration_order,
        branch_key_field: :branch,
        agent_field: :agent,
        output_field: :output,
        failure: :discard_all_branch_results_on_failure
      },
      resume_contract: {
        granularity: :transition,
        branch_checkpointing: false,
        idempotency_mode: :lax,
        in_flight_resume: :reruns_transition
      },
      branches: [
        { branch: :static, agent: :spec_fanout_static_agent },
        { branch: :security, agent: :spec_fanout_security_agent }
      ],
      branch_contracts: [
        {
          branch: :static,
          agent: :spec_fanout_static_agent,
          result_branch_value: :static,
          result_shape: {
            branch: :static,
            agent: :spec_fanout_static_agent,
            output: :agent_output
          }
        },
        {
          branch: :security,
          agent: :spec_fanout_security_agent,
          result_branch_value: :security,
          result_shape: {
            branch: :security,
            agent: :spec_fanout_security_agent,
            output: :agent_output
          }
        }
      ]
    )
    expect(transition.to_h.fetch(:fanout)).to be_frozen
    expect(transition.to_h.fetch(:fanout).fetch(:branches)).to be_frozen
    expect(transition.to_h.fetch(:fanout).fetch(:branches).first).to be_frozen
    expect(transition.to_h.fetch(:fanout).fetch(:branch_contracts)).to be_frozen
    expect(transition.to_h.fetch(:fanout).fetch(:branch_contracts).first.fetch(:result_shape)).to be_frozen
  end

  it "does not freeze workflow-owned topology values during fanout graph inspection" do
    idle = +"idle"
    reviewed = +"reviewed"
    review = +"review"

    workflow = with_stubbed_class("SpecFanoutGraphImmutabilityWorkflow", workflow_class) do
      initial_state idle
      state reviewed

      transition review, from: idle, to: reviewed do
        fan_out branches: {
          static: :spec_fanout_static_agent,
          security: :spec_fanout_security_agent
        }
      end
    end

    workflow.validate_graph

    expect(idle).not_to be_frozen
    expect(reviewed).not_to be_frozen
    expect(review).not_to be_frozen
  end

  it "reports fanout resume behavior according to workflow idempotency mode" do
    strict_workflow = with_stubbed_class("SpecFanoutStrictResumeWorkflow", workflow_class) do
      idempotency_mode :strict
      initial_state :idle
      state :reviewed

      transition :review, from: :idle, to: :reviewed do
        fan_out branches: {
          static: :spec_fanout_static_agent,
          security: :spec_fanout_security_agent
        }
      end
    end

    strict_fanout = strict_workflow
      .validate_graph
      .transitions
      .find { |snapshot| snapshot.name == :review }
      .to_h
      .fetch(:fanout)
      .fetch(:resume_contract)

    expect(strict_fanout).to include(
      idempotency_mode: :strict,
      in_flight_resume: :blocked_by_step_in_progress
    )
  end
end
