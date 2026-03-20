# frozen_string_literal: true

RSpec.describe "Smith::Workflow parallel execution" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:context_class) { require_const("Smith::Context") }
  let(:guardrails_class) { require_const("Smith::Guardrails") }
  let(:tool_class) { require_const("Smith::Tool") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:workflow_error) { require_const("Smith::WorkflowError") }

  it "returns one branch result per configured branch when a parallel transition succeeds" do
    workflow = with_stubbed_class("SpecParallelWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: 3
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.steps.length).to eq(1)
    expect(result.output).to eq(
      [
        { branch: 0, agent: :spec_parallel_agent, output: nil },
        { branch: 1, agent: :spec_parallel_agent, output: nil },
        { branch: 2, agent: :spec_parallel_agent, output: nil }
      ]
    )
  end

  it "uses a callable branch count with the workflow context" do
    workflow = with_stubbed_class("SpecParallelCallableCountWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: ->(context) { context.fetch(:branch_count) }
      end
    end.new(context: { branch_count: 2 })

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output.length).to eq(2)
    expect(result.output.map { |branch| branch[:branch] }).to eq([0, 1])
  end

  it "routes through on_failure when a parallel branch fails" do
    workflow = with_stubbed_class("SpecParallelFailureWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :done
      state :failed

      transition :fan_out, from: :idle, to: :running do
        execute :spec_parallel_agent, parallel: true, count: 3
        on_failure :fail
      end

      transition :finish, from: :running, to: :done
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      @parallel_calls ||= 0
      @parallel_calls += 1
      raise Smith::WorkflowError, "branch failed" if @parallel_calls == 1

      :ok
    end

    result = workflow.run!

    expect(workflow.state).to eq(:failed)
    expect(result.state).to eq(:failed)
    expect(result.steps.length).to eq(1)
    expect(result.steps.first[:transition]).to eq(:fan_out)
    expect(result.steps.first[:error]).to be_a(workflow_error)
  end

  it "does not surface successful branch outputs when a parallel step fails" do
    workflow = with_stubbed_class("SpecParallelDiscardWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :done
      state :failed

      transition :fan_out, from: :idle, to: :running do
        execute :spec_parallel_agent, parallel: true, count: 3
        on_failure :fail
      end

      transition :finish, from: :running, to: :done
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      @parallel_calls ||= 0
      @parallel_calls += 1
      return :ok if @parallel_calls == 1

      raise Smith::WorkflowError, "branch failed"
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.output).to be_nil
    expect(result.steps.first).not_to have_key(:output)
    expect(result.steps.first[:error]).to be_a(workflow_error)
  end

  it "reuses the prepared input for each parallel branch execution" do
    manager = with_stubbed_class("SpecParallelPreparedInputContext", context_class) do
      session_strategy :observation_masking, window: 1

      inject_state do |persisted|
        "summary: #{persisted[:current_findings]}"
      end
    end

    seen_branch_inputs = []
    agent = with_stubbed_class("SpecParallelPreparedInputAgent", agent_class) do
      register_as :spec_parallel_prepared_input_agent
      model "gpt-5-mini"
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      messages = []

      chat.define_singleton_method(:add_message) do |message|
        messages << message
      end
      chat.define_singleton_method(:complete) do
        seen_branch_inputs << messages.dup
        Struct.new(:content).new("ok")
      end

      chat
    end

    workflow = with_stubbed_class("SpecParallelPreparedInputWorkflow", workflow_class) do
      context_manager manager
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_prepared_input_agent, parallel: true, count: 2
      end
    end.new(context: { current_findings: "stable" })

    workflow.instance_variable_set(
      :@session_messages,
      [
        { role: :user, content: "older" },
        { role: :assistant, content: "middle" },
        { role: :user, content: "latest" }
      ]
    )

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(seen_branch_inputs).to eq(
      [
        [
          { role: :system, content: "[smith:injected-state]\nsummary: stable" },
          { role: :user, content: "latest" }
        ],
        [
          { role: :system, content: "[smith:injected-state]\nsummary: stable" },
          { role: :user, content: "latest" }
        ]
      ]
    )
  end

  it "applies attached tool guardrails inside parallel branch threads" do
    observed = Queue.new

    guardrailed_tool = with_stubbed_class("SpecParallelGuardrailedTool", tool_class) do
      def perform(**kwargs)
        kwargs
      end
    end
    tool_name = guardrailed_tool.new.name.to_sym

    workflow_guardrails = with_stubbed_class("SpecParallelToolGuardrails", guardrails_class) do
      define_method(:capture_tool_payload) do |payload|
        observed << payload
      end

      tool :capture_tool_payload, on: [tool_name]
    end

    with_stubbed_class("SpecParallelToolGuardrailAgent", agent_class) do
      register_as :spec_parallel_tool_guardrail_agent
    end

    workflow = with_stubbed_class("SpecParallelToolGuardrailWorkflow", workflow_class) do
      initial_state :idle
      state :done
      guardrails workflow_guardrails

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_tool_guardrail_agent, parallel: true, count: 2
      end
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      guardrailed_tool.new.execute(context: @context, branch: Thread.current.object_id, prepared_input: prepared_input)
      :ok
    end

    result = workflow.run!

    expect(result.state).to eq(:done)
    observed_payloads = []
    observed_payloads << observed.pop until observed.empty?

    expect(observed_payloads.length).to eq(2)
    expect(observed_payloads).to all(include(context: {}))
    expect(observed_payloads).to all(include(:branch, :prepared_input))
  end

  it "reserves and reconciles workflow budget for successful parallel branches" do
    workflow = with_stubbed_class("SpecParallelBudgetSuccessWorkflow", workflow_class) do
      initial_state :idle
      state :done
      budget total_tokens: 100, total_cost: 1.0

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: 2
      end
    end.new

    observed = Queue.new
    ledger = workflow.ledger

    allow(ledger).to receive(:reserve!).and_wrap_original do |original, key, amount|
      observed << [:reserve, key, amount]
      original.call(key, amount)
    end
    allow(ledger).to receive(:reconcile!).and_wrap_original do |original, key, reserved_amount, actual_amount|
      observed << [:reconcile, key, reserved_amount, actual_amount]
      original.call(key, reserved_amount, actual_amount)
    end
    allow(ledger).to receive(:release!).and_wrap_original do |original, key, amount|
      observed << [:release, key, amount]
      original.call(key, amount)
    end

    result = workflow.run!

    expect(result.state).to eq(:done)
    entries = []
    entries << observed.pop until observed.empty?

    reserve_entries = entries.select { |entry| entry[0] == :reserve }
    reconcile_entries = entries.select { |entry| entry[0] == :reconcile }
    release_entries = entries.select { |entry| entry[0] == :release }

    expect(reserve_entries).to contain_exactly(
      [:reserve, :total_tokens, 50],
      [:reserve, :total_cost, 0],
      [:reserve, :total_tokens, 50],
      [:reserve, :total_cost, 0]
    )
    expect(reconcile_entries).to contain_exactly(
      [:reconcile, :total_tokens, 50, 0],
      [:reconcile, :total_cost, 0, 0],
      [:reconcile, :total_tokens, 50, 0],
      [:reconcile, :total_cost, 0, 0]
    )
    expect(release_entries).to eq([])
  end

  it "releases reserved workflow budget when a parallel branch fails" do
    workflow = with_stubbed_class("SpecParallelBudgetFailureWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed
      budget total_tokens: 100, total_cost: 1.0

      transition :fan_out, from: :idle, to: :running do
        execute :spec_parallel_agent, parallel: true, count: 2
        on_failure :fail
      end
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      @parallel_calls ||= 0
      @parallel_calls += 1
      raise Smith::WorkflowError, "branch failed" if @parallel_calls == 1

      sleep 0.01
      :ok
    end

    observed = Queue.new
    ledger = workflow.ledger

    allow(ledger).to receive(:reserve!).and_wrap_original do |original, key, amount|
      observed << [:reserve, key, amount]
      original.call(key, amount)
    end
    allow(ledger).to receive(:reconcile!).and_wrap_original do |original, key, reserved_amount, actual_amount|
      observed << [:reconcile, key, reserved_amount, actual_amount]
      original.call(key, reserved_amount, actual_amount)
    end
    allow(ledger).to receive(:release!).and_wrap_original do |original, key, amount|
      observed << [:release, key, amount]
      original.call(key, amount)
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    entries = []
    entries << observed.pop until observed.empty?

    reserve_entries = entries.select { |entry| entry[0] == :reserve }
    release_entries = entries.select { |entry| entry[0] == :release }

    expect(reserve_entries.length).to be >= 2
    expect(release_entries.length).to be >= 2
    expect(release_entries).to all(satisfy { |entry| entry[2] >= 0 })
  end
end
