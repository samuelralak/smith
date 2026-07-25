# frozen_string_literal: true

RSpec.describe "Smith::Workflow execution context lifecycle" do
  it "routes setup failures through the transition failure path and always tears down" do
    events = []
    base = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      state :failed
      transition :finish, from: :idle, to: :done do
        compute { :unused }
        on_failure :fail
      end
    end
    workflow_class = Class.new(base) do
      define_method(:setup_step_context) do
        events << :setup
        super()
        raise "setup failed"
      end

      define_method(:teardown_step_context) do
        events << :teardown
        super()
      end

      private :setup_step_context, :teardown_step_context
    end

    result = workflow_class.new.run!

    expect(result).to be_failed
    expect(result.steps.one? { _1[:error]&.message&.include?("setup failed") }).to be(true)
    expect(events).to eq(%i[setup teardown])
  end

  it "preserves agent cleanup extension points" do
    events = []
    Smith::Agent::Registry.register(:context_lifecycle_agent, Class.new(Smith::Agent))
    base = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { execute :context_lifecycle_agent }
    end
    workflow_class = Class.new(base) do
      define_method(:clear_agent_deadline) do
        events << :deadline
        super()
      end

      define_method(:clear_agent_tool_calls) do
        events << :tool_calls
        super()
      end

      private :clear_agent_deadline, :clear_agent_tool_calls
    end

    expect(workflow_class.new.run!).to be_done
    expect(events).to eq(%i[deadline tool_calls])
  ensure
    Smith::Agent::Registry.delete(:context_lifecycle_agent)
  end

  it "allows a zero-call agent budget when the agent invokes no tools" do
    agent = Class.new(Smith::Agent) do
      register_as :zero_tool_call_agent
      model "gpt-5-mini"
      budget tool_calls: 0
    end
    allow(agent).to receive(:chat) do
      Object.new.tap do |chat|
        chat.define_singleton_method(:add_message) { |_message| nil }
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("done", 1, 1)
        end
      end
    end
    workflow = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { execute :zero_tool_call_agent }
    end.new

    expect(workflow.run!).to be_done
  ensure
    Smith::Agent::Registry.delete(:zero_tool_call_agent)
  end

  it "rejects graceful exhaustion without a finite agent tool-call budget" do
    agent = Class.new(Smith::Agent) do
      register_as :unbounded_graceful_tool_agent
      model "gpt-5-mini"
      tool_budget_exhaustion :complete
    end
    allow(agent).to receive(:chat) { raise "chat must not be constructed" }
    workflow = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      state :failed
      transition :finish, from: :idle, to: :done do
        execute :unbounded_graceful_tool_agent
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result).to be_failed
    expect(result.last_error).to be_a(Smith::AgentError)
    expect(result.last_error.message).to eq(
      "tool_budget_exhaustion :complete requires a finite tool_calls budget"
    )
    expect(agent).not_to have_received(:chat)
  ensure
    Smith::Agent::Registry.delete(:unbounded_graceful_tool_agent)
  end

  it "denies an actual tool invocation under a zero-call agent budget" do
    executed = false
    tool = Class.new(Smith::Tool) do
      define_method(:perform) do |**_kwargs|
        executed = true
        :unreachable
      end
    end.new
    agent = Class.new(Smith::Agent) do
      register_as :zero_tool_call_denial_agent
      model "gpt-5-mini"
      budget tool_calls: 0
    end
    allow(agent).to receive(:chat) do
      Object.new.tap do |chat|
        chat.define_singleton_method(:add_message) { |_message| nil }
        chat.define_singleton_method(:complete) { tool.execute }
      end
    end
    workflow = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      state :failed
      transition :finish, from: :idle, to: :done do
        execute :zero_tool_call_denial_agent
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result).to be_failed
    expect(result.last_error).to be_a(Smith::BudgetExceeded)
    expect(executed).to eq(false)
  ensure
    Smith::Agent::Registry.delete(:zero_tool_call_denial_agent)
  end

  it "accounts for every assistant response in a successful tool loop" do
    response_class = Struct.new(:role, :content, :input_tokens, :output_tokens)
    final_response = response_class.new(
      role: :assistant,
      content: "complete",
      input_tokens: 5,
      output_tokens: 7
    )
    agent = Class.new(Smith::Agent) do
      register_as :tool_loop_usage_agent
      model "gpt-5-mini"
    end
    allow(agent).to receive(:chat) do
      Object.new.tap do |chat|
        messages = []
        chat.define_singleton_method(:messages) { messages }
        chat.define_singleton_method(:add_message) { |message| messages << message }
        chat.define_singleton_method(:complete) do
          messages << response_class.new(
            role: :assistant,
            content: nil,
            input_tokens: 2,
            output_tokens: 3
          )
          messages << response_class.new(role: :tool, content: "evidence")
          messages << final_response
          final_response
        end
      end
    end
    workflow = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { execute :tool_loop_usage_agent }
    end.new

    result = workflow.run!

    expect(result).to be_done
    expect(result.output).to eq("complete")
    expect(result.total_tokens).to eq(17)
  ensure
    Smith::Agent::Registry.delete(:tool_loop_usage_agent)
  end

  it "tears down a branch when branch setup raises" do
    events = []
    Smith::Agent::Registry.register(:branch_lifecycle_agent, Class.new(Smith::Agent))
    base = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      state :failed
      transition :finish, from: :idle, to: :done do
        execute :branch_lifecycle_agent, parallel: true, count: 1
        on_failure :fail
      end
    end
    workflow_class = Class.new(base) do
      define_method(:setup_branch_context) do |environment, ledger|
        super(environment, ledger)
        events << :setup
        raise "branch setup failed"
      end

      define_method(:teardown_branch_context) do |environment|
        events << :teardown
        super(environment)
      end

      private :setup_branch_context, :teardown_branch_context
    end

    result = workflow_class.new.run!

    expect(result).to be_failed
    expect(result.steps.one? { _1[:error]&.message&.include?("branch setup failed") }).to be(true)
    expect(events).to eq(%i[setup teardown])
  ensure
    Smith::Agent::Registry.delete(:branch_lifecycle_agent)
  end

  it "shares the enclosing exact tool allowance across same-agent parallel branches" do
    admissions = Queue.new
    budget = Smith::Tool::CallBudget.new(total: 1, tool_limits: { "weather" => 1 })
    Class.new(Smith::Agent) do
      register_as :shared_parallel_allowance_agent
      budget tool_calls: budget
    end
    base = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :shared_parallel_allowance_agent, parallel: true, count: 2
      end
    end
    workflow_class = Class.new(base) do
      define_method(:guarded_branch_call) do |_transition, _environment, _signal|
        reservation = Smith::Tool.current_tool_call_allowance.reserve_batch(["weather"])
        reservation&.settle!
        admissions << !reservation.nil?
        :done
      end

      private :guarded_branch_call
    end

    result = Smith::Tool.with_call_budget(budget, on_exhaustion: :complete) do
      workflow_class.new.run!
    end

    expect(result).to be_done
    expect(2.times.map { admissions.pop }.sort_by(&:to_s)).to eq([false, true])
  ensure
    Smith::Agent::Registry.delete(:shared_parallel_allowance_agent)
  end

  it "shares the enclosing exact tool allowance across heterogeneous fanout branches" do
    admissions = Queue.new
    budget = Smith::Tool::CallBudget.new(total: 1, tool_limits: { "weather" => 1 })
    %i[first_shared_fanout_agent second_shared_fanout_agent].each do |name|
      Class.new(Smith::Agent) do
        register_as name
        budget tool_calls: budget
      end
    end
    base = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        fan_out(
          branches: {
            first: :first_shared_fanout_agent,
            second: :second_shared_fanout_agent
          }
        )
      end
    end
    workflow_class = Class.new(base) do
      define_method(:guarded_fanout_branch_call) do |_agent_class, _environment, _signal|
        reservation = Smith::Tool.current_tool_call_allowance.reserve_batch(["weather"])
        reservation&.settle!
        admissions << !reservation.nil?
        :done
      end

      private :guarded_fanout_branch_call
    end

    result = Smith::Tool.with_call_budget(budget, on_exhaustion: :complete) do
      workflow_class.new.run!
    end

    expect(result).to be_done
    expect(2.times.map { admissions.pop }.sort_by(&:to_s)).to eq([false, true])
  ensure
    Smith::Agent::Registry.delete(:first_shared_fanout_agent)
    Smith::Agent::Registry.delete(:second_shared_fanout_agent)
  end
end
