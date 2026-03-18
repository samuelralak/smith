# frozen_string_literal: true

RSpec.describe "Smith::Workflow parallel execution" do
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

    workflow.define_singleton_method(:execute_transition_body) do |_transition|
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

    workflow.define_singleton_method(:execute_transition_body) do |_transition|
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
end
