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
end
