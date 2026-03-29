# frozen_string_literal: true

RSpec.describe "Smith::Workflow parallel execution" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:context_class) { require_const("Smith::Context") }
  let(:guardrails_class) { require_const("Smith::Guardrails") }
  let(:tool_class) { require_const("Smith::Tool") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:workflow_error) { require_const("Smith::WorkflowError") }
  let!(:parallel_agent) do
    with_stubbed_class("SpecParallelAgent", agent_class) do
      register_as :spec_parallel_agent
    end
  end

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

  it "cancels sibling branches cooperatively at the next check boundary" do
    cancellation_observations = Queue.new
    started_barrier = Concurrent::CountDownLatch.new(3)
    call_counter = Concurrent::AtomicFixnum.new(0)

    workflow = with_stubbed_class("SpecParallelCoopCancelWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: 3
        on_failure :fail
      end
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      branch = call_counter.increment
      started_barrier.count_down
      started_barrier.wait(1)

      if branch == 1
        raise Smith::WorkflowError, "branch failed"
      end

      sleep 0.05
      :ok
    end

    workflow.define_singleton_method(:check_cancellation!) do |signal|
      if signal.cancelled?
        cancellation_observations << Thread.current.object_id
        raise Smith::WorkflowError, "cancelled"
      end
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)

    observed = []
    observed << cancellation_observations.pop until cancellation_observations.empty?
    expect(observed.length).to be >= 1
  end

  it "does not interrupt in-flight branch work but discards its output on step failure" do
    branch_outputs = Queue.new
    call_counter = Concurrent::AtomicFixnum.new(0)

    workflow = with_stubbed_class("SpecParallelInflightWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: 2
        on_failure :fail
      end
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      branch = call_counter.increment

      if branch == 1
        sleep 0.05
        branch_outputs << :branch_0_completed
        :branch_0_result
      else
        raise Smith::WorkflowError, "branch failed"
      end
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.output).to be_nil

    finished = []
    finished << branch_outputs.pop until branch_outputs.empty?
    expect(finished).to include(:branch_0_completed)
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
      [:reserve, :total_cost, 0.5],
      [:reserve, :total_tokens, 50],
      [:reserve, :total_cost, 0.5]
    )
    expect(reconcile_entries).to contain_exactly(
      [:reconcile, :total_tokens, 50, 0],
      [:reconcile, :total_cost, 0.5, 0],
      [:reconcile, :total_tokens, 50, 0],
      [:reconcile, :total_cost, 0.5, 0]
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

  it "uses a token reservation floor of 1 for positive limits smaller than branch count" do
    workflow = with_stubbed_class("SpecParallelBudgetFloorWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed
      budget total_tokens: 1

      transition :fan_out, from: :idle, to: :running do
        execute :spec_parallel_agent, parallel: true, count: 2
        on_failure :fail
      end
    end.new

    observed = Queue.new
    ledger = workflow.ledger

    allow(ledger).to receive(:reserve!).and_wrap_original do |original, key, amount|
      observed << [:reserve, key, amount]
      original.call(key, amount)
    end

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      sleep 0.05
      super(_transition, prepared_input: prepared_input)
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    entries = []
    entries << observed.pop until observed.empty?

    reserve_entries = entries.select { |entry| entry[0] == :reserve }
    expect(reserve_entries).to include([:reserve, :total_tokens, 1])
    expect(reserve_entries.length).to be >= 2
  end

  it "denies a parallel branch before branch work when reservation would exceed budget" do
    budget_exceeded = require_const("Smith::BudgetExceeded")

    workflow = with_stubbed_class("SpecParallelBudgetDeniedWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed
      budget total_tokens: 1

      transition :fan_out, from: :idle, to: :running do
        execute :spec_parallel_agent, parallel: true, count: 2
        on_failure :fail
      end
    end.new

    reservation_failures = Queue.new
    ledger = workflow.ledger

    allow(ledger).to receive(:reserve!).and_wrap_original do |original, key, amount|
      original.call(key, amount)
    rescue budget_exceeded => e
      reservation_failures << [key, amount, e.class]
      raise
    end

    executed = Queue.new
    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      executed << :ran
      sleep 0.05
      super(_transition, prepared_input: prepared_input)
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(workflow.state).to eq(:failed)
    expect(executed.size).to eq(1)
    failures = []
    failures << reservation_failures.pop until reservation_failures.empty?
    expect(failures).to include([:total_tokens, 1, budget_exceeded])
  end

  it "reconciles parallel branch reservations with response token metadata" do
    agent = with_stubbed_class("SpecParallelBudgetTokenAgent", agent_class) do
      register_as :spec_parallel_budget_token_agent
      model "gpt-5-mini"
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_message| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("ok", 7, 5)
      end
      chat
    end

    workflow = with_stubbed_class("SpecParallelBudgetTokenWorkflow", workflow_class) do
      initial_state :idle
      state :done
      budget total_tokens: 100

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_budget_token_agent, parallel: true, count: 2
      end
    end.new

    observed = Queue.new
    ledger = workflow.ledger

    allow(ledger).to receive(:reconcile!).and_wrap_original do |original, key, reserved_amount, actual_amount|
      observed << [:reconcile, key, reserved_amount, actual_amount]
      original.call(key, reserved_amount, actual_amount)
    end

    result = workflow.run!

    expect(result.state).to eq(:done)
    entries = []
    entries << observed.pop until observed.empty?

    reconcile_entries = entries.select { |entry| entry[0] == :reconcile }
    expect(reconcile_entries).to contain_exactly(
      [:reconcile, :total_tokens, 50, 12],
      [:reconcile, :total_tokens, 50, 12]
    )
  end

  it "bases parallel branch estimates on remaining budget after prior serial consumption" do
    serial_agent = with_stubbed_class("SpecMixedBudgetSerialAgent", agent_class) do
      register_as :spec_mixed_budget_serial_agent
      model "gpt-5-mini"
    end

    parallel_agent = with_stubbed_class("SpecMixedBudgetParallelAgent", agent_class) do
      register_as :spec_mixed_budget_parallel_agent
      model "gpt-5-mini"
    end

    serial_chat = Object.new
    serial_chat.define_singleton_method(:add_message) { |_message| nil }
    serial_chat.define_singleton_method(:complete) do
      Struct.new(:content, :input_tokens, :output_tokens).new("serial", 20, 15)
    end

    parallel_chat = Object.new
    parallel_chat.define_singleton_method(:add_message) { |_message| nil }
    parallel_chat.define_singleton_method(:complete) do
      Struct.new(:content, :input_tokens, :output_tokens).new("parallel", 0, 0)
    end

    allow(serial_agent).to receive(:chat).and_return(serial_chat)
    allow(parallel_agent).to receive(:chat).and_return(parallel_chat)

    workflow = with_stubbed_class("SpecMixedBudgetWorkflow", workflow_class) do
      initial_state :idle
      state :serial_done
      state :done
      budget total_tokens: 50_000

      transition :serial_step, from: :idle, to: :serial_done do
        execute :spec_mixed_budget_serial_agent
        on_success :fan_out
      end

      transition :fan_out, from: :serial_done, to: :done do
        execute :spec_mixed_budget_parallel_agent, parallel: true, count: 2
      end
    end.new

    observed = Queue.new
    ledger = workflow.ledger

    allow(ledger).to receive(:reserve!).and_wrap_original do |original, key, amount|
      observed << [:reserve, key, amount]
      original.call(key, amount)
    end

    result = workflow.run!

    expect(result.state).to eq(:done)
    entries = []
    entries << observed.pop until observed.empty?

    total_token_reserves = entries.select { |entry| entry[0] == :reserve && entry[1] == :total_tokens }
    expect(total_token_reserves).to include([:reserve, :total_tokens, 50_000])
    expect(total_token_reserves.count([:reserve, :total_tokens, 24_982])).to eq(2)
  end

  it "enforces agent-only token_limit per parallel branch invocation without a workflow budget" do
    budget_ledger_class = require_const("Smith::Budget::Ledger")

    agent = with_stubbed_class("SpecParallelAgentOnlyTokenBudgetAgent", agent_class) do
      register_as :spec_parallel_agent_only_token_budget_agent
      model "gpt-5-mini"
      budget token_limit: 10
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_message| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("ok", 7, 5)
      end
      chat
    end

    observed = Queue.new
    created_ledgers = []

    allow(budget_ledger_class).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      ledger = original.call(*args, **kwargs)
      if ledger.limits == { token_limit: 10 }
        created_ledgers << ledger
        allow(ledger).to receive(:reserve!).and_wrap_original do |inner, key, amount|
          observed << [:reserve, ledger.object_id, key, amount]
          inner.call(key, amount)
        end
        allow(ledger).to receive(:reconcile!).and_wrap_original do |inner, key, reserved_amount, actual_amount|
          observed << [:reconcile, ledger.object_id, key, reserved_amount, actual_amount]
          inner.call(key, reserved_amount, actual_amount)
        end
      end
      ledger
    end

    workflow = with_stubbed_class("SpecParallelAgentOnlyTokenBudgetWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent_only_token_budget_agent, parallel: true, count: 2
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(workflow.ledger).to be_nil
    expect(created_ledgers.length).to be >= 2

    entries = []
    entries << observed.pop until observed.empty?

    reserve_entries = entries.select { |entry| entry[0] == :reserve }
    reconcile_entries = entries.select { |entry| entry[0] == :reconcile }
    used_ledger_ids = (reserve_entries + reconcile_entries).map { |entry| entry[1] }.uniq

    expect(used_ledger_ids.length).to eq(2)
    expect(reserve_entries).to contain_exactly(
      [:reserve, used_ledger_ids[0], :token_limit, 10],
      [:reserve, used_ledger_ids[1], :token_limit, 10]
    )
    expect(reconcile_entries).to contain_exactly(
      [:reconcile, used_ledger_ids[0], :token_limit, 10, 12],
      [:reconcile, used_ledger_ids[1], :token_limit, 10, 12]
    )
  end

  it "enforces agent-only cost per parallel branch invocation without a workflow budget" do
    budget_ledger_class = require_const("Smith::Budget::Ledger")
    original_pricing = Smith.config.pricing

    Smith.configure do |config|
      config.pricing = {
        "gpt-5-mini" => {
          input_cost_per_token: 0.01,
          output_cost_per_token: 0.02
        }
      }
    end

    agent = with_stubbed_class("SpecParallelAgentOnlyCostBudgetAgent", agent_class) do
      register_as :spec_parallel_agent_only_cost_budget_agent
      model "gpt-5-mini"
      budget cost: 0.20
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_message| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("ok", 7, 5)
      end
      chat
    end

    observed = Queue.new
    created_ledgers = []

    allow(budget_ledger_class).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      ledger = original.call(*args, **kwargs)
      if ledger.limits == { total_cost: 0.20 }
        created_ledgers << ledger
        allow(ledger).to receive(:reserve!).and_wrap_original do |inner, key, amount|
          observed << [:reserve, ledger.object_id, key, amount]
          inner.call(key, amount)
        end
        allow(ledger).to receive(:reconcile!).and_wrap_original do |inner, key, reserved_amount, actual_amount|
          observed << [:reconcile, ledger.object_id, key, reserved_amount, actual_amount]
          inner.call(key, reserved_amount, actual_amount)
        end
      end
      ledger
    end

    workflow = with_stubbed_class("SpecParallelAgentOnlyCostBudgetWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent_only_cost_budget_agent, parallel: true, count: 2
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(workflow.ledger).to be_nil
    expect(created_ledgers.length).to be >= 2

    entries = []
    entries << observed.pop until observed.empty?

    reserve_entries = entries.select { |entry| entry[0] == :reserve }
    reconcile_entries = entries.select { |entry| entry[0] == :reconcile }
    used_ledger_ids = (reserve_entries + reconcile_entries).map { |entry| entry[1] }.uniq

    expect(used_ledger_ids.length).to eq(2)
    expect(reserve_entries).to contain_exactly(
      [:reserve, used_ledger_ids[0], :total_cost, 0.20],
      [:reserve, used_ledger_ids[1], :total_cost, 0.20]
    )
    expect(reconcile_entries).to contain_exactly(
      [:reconcile, used_ledger_ids[0], :total_cost, 0.20, 0.17],
      [:reconcile, used_ledger_ids[1], :total_cost, 0.20, 0.17]
    )
  ensure
    Smith.configure { |config| config.pricing = original_pricing }
  end

  it "treats agent-only parallel budgets as per-branch ledgers rather than one shared pool" do
    budget_ledger_class = require_const("Smith::Budget::Ledger")

    agent = with_stubbed_class("SpecParallelPerBranchAgentBudgetAgent", agent_class) do
      register_as :spec_parallel_per_branch_agent_budget_agent
      model "gpt-5-mini"
      budget token_limit: 10
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_message| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("ok", 1, 0)
      end
      chat
    end

    created_ledgers = []

    allow(budget_ledger_class).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      ledger = original.call(*args, **kwargs)
      created_ledgers << ledger if ledger.limits == { token_limit: 10 }
      ledger
    end

    workflow = with_stubbed_class("SpecParallelPerBranchAgentBudgetWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_per_branch_agent_budget_agent, parallel: true, count: 2
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)

    used_ledgers = created_ledgers.select { |ledger| ledger.consumed[:token_limit] == 1 }

    expect(used_ledgers.length).to eq(2)
    expect(used_ledgers.map(&:object_id).uniq.length).to eq(2)
    expect(used_ledgers.map { |ledger| ledger.consumed[:token_limit] }).to eq([1, 1])
  end

  it "captures tool results from parallel branches without loss" do
    tool_class = require_const("Smith::Tool")

    capturing_tool = with_stubbed_class("SpecParallelCaptureTool", tool_class) do
      capture_result { |kwargs, _result| { branch: kwargs[:branch_id] } }
      def perform(branch_id:, **) = "result-#{branch_id}"
    end

    agent = with_stubbed_class("SpecParallelCaptureAgent", agent_class) do
      register_as :spec_parallel_capture_agent
      model "gpt-5-mini"
    end

    branch_index = Concurrent::AtomicFixnum.new(0)
    allow(agent).to receive(:chat) do
      idx = branch_index.increment
      tool_instance = capturing_tool.new
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:complete) do
        tool_instance.execute(branch_id: idx)
        Struct.new(:content).new("branch-#{idx}")
      end
      chat
    end

    workflow = with_stubbed_class("SpecParallelCaptureWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_capture_agent, parallel: true, count: 3
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.tool_results.length).to eq(3)

    captured_branches = result.tool_results.map { |tr| tr[:captured][:branch] }.sort
    expect(captured_branches).to eq([1, 2, 3])
  end

  it "captures all entries from 50 parallel branches without loss" do
    tool_class = require_const("Smith::Tool")

    capturing_tool = with_stubbed_class("SpecHighBranchCaptureTool", tool_class) do
      capture_result { |kwargs, _result| { branch: kwargs[:branch_id] } }
      def perform(branch_id:, **) = "result-#{branch_id}"
    end

    agent = with_stubbed_class("SpecHighBranchCaptureAgent", agent_class) do
      register_as :spec_high_branch_capture_agent
      model "gpt-5-mini"
    end

    branch_index = Concurrent::AtomicFixnum.new(0)
    allow(agent).to receive(:chat) do
      idx = branch_index.increment
      tool_instance = capturing_tool.new
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:complete) do
        tool_instance.execute(branch_id: idx)
        Struct.new(:content).new("branch-#{idx}")
      end
      chat
    end

    workflow = with_stubbed_class("SpecHighBranchCaptureWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_high_branch_capture_agent, parallel: true, count: 50
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.tool_results.length).to eq(50)
    expect(result.tool_results.map { |tr| tr[:captured][:branch] }.sort).to eq((1..50).to_a)
  end
end
