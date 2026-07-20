# frozen_string_literal: true

RSpec.describe "Smith::Workflow retry policy" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:workflow_error) { require_const("Smith::WorkflowError") }

  before do
    with_stubbed_class("SpecRetryAgent", agent_class) do
      register_as :spec_retry_agent
    end
  end

  it "retries retryable Smith errors and completes the transition once" do
    workflow = with_stubbed_class("SpecRetrySuccessWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :call_agent, from: :idle, to: :done do
        execute :spec_retry_agent
        retry_on attempts: 3
      end
    end.new

    attempts = 0
    workflow.define_singleton_method(:execute_transition_body) do |_transition, **|
      attempts += 1
      raise Smith::AgentError, "temporary outage" if attempts < 3

      :ok
    end

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq(:ok)
    expect(result.steps.length).to eq(1)
    expect(attempts).to eq(3)
  end

  it "routes to failure after retry attempts are exhausted" do
    workflow = with_stubbed_class("SpecRetryExhaustionWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :call_agent, from: :idle, to: :done do
        execute :spec_retry_agent
        retry_on attempts: 2
        on_failure :fail
      end
    end.new

    attempts = 0
    workflow.define_singleton_method(:execute_transition_body) do |_transition, **|
      attempts += 1
      raise Smith::AgentError, "still down"
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.output).to be_nil
    expect(result.steps.length).to eq(1)
    expect(result.steps.first[:error]).to be_a(Smith::AgentError)
    expect(attempts).to eq(2)
  end

  it "does not retry non-retryable errors unless explicitly listed" do
    workflow = with_stubbed_class("SpecRetryDefaultClassifierWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :call_agent, from: :idle, to: :done do
        execute :spec_retry_agent
        retry_on attempts: 3
        on_failure :fail
      end
    end.new

    attempts = 0
    workflow.define_singleton_method(:execute_transition_body) do |_transition, **|
      attempts += 1
      raise Smith::WorkflowError, "programmer error"
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(workflow_error)
    expect(attempts).to eq(1)
  end

  it "honors explicit retry classes" do
    workflow = with_stubbed_class("SpecRetryExplicitClassWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :call_agent, from: :idle, to: :done do
        execute :spec_retry_agent
        retry_on Smith::WorkflowError, attempts: 2
      end
    end.new

    attempts = 0
    workflow.define_singleton_method(:execute_transition_body) do |_transition, **|
      attempts += 1
      raise Smith::WorkflowError, "retry me" if attempts == 1

      :ok
    end

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq(:ok)
    expect(attempts).to eq(2)
  end

  it "rejects explicit retries for post-execution tool capture uncertainty" do
    expect do
      with_stubbed_class("SpecRetryCaptureFailureWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :call_agent, from: :idle, to: :done do
          execute :spec_retry_agent
          retry_on Smith::ToolCaptureFailed, attempts: 2
        end
      end
    end.to raise_error(
      workflow_error,
      "retry_on cannot retry Smith::ToolCaptureFailed because the tool outcome may be uncertain"
    )
  end

  it "does not let broad explicit retry classes override capture uncertainty" do
    attempts = 0
    workflow = Class.new(workflow_class) do
      initial_state :idle
      state :done

      transition :call_agent, from: :idle, to: :done do
        execute :spec_retry_agent
        retry_on StandardError, attempts: 3
      end
    end.new
    workflow.define_singleton_method(:execute_transition_body) do |_transition, **|
      attempts += 1
      raise Smith::ToolCaptureFailed.new(tool_name: :search, reason: :collector_failed)
    end

    expect { workflow.run! }.to raise_error(Smith::ToolCaptureFailed)
    expect(attempts).to eq(1)
  end

  it "validates retry controls at declaration time" do
    expect do
      with_stubbed_class("SpecRetryInvalidAttemptsWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :call_agent, from: :idle, to: :done do
          execute :spec_retry_agent
          retry_on attempts: 0
        end
      end
    end.to raise_error(workflow_error, /attempts/)

    expect do
      with_stubbed_class("SpecRetryInvalidClassWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :call_agent, from: :idle, to: :done do
          execute :spec_retry_agent
          retry_on String, attempts: 2
        end
      end
    end.to raise_error(workflow_error, /StandardError/)

    expect do
      with_stubbed_class("SpecRetryInvalidDelayWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :call_agent, from: :idle, to: :done do
          execute :spec_retry_agent
          retry_on attempts: 2, backoff: -0.1
        end
      end
    end.to raise_error(workflow_error, /backoff/)

    expect do
      with_stubbed_class("SpecRetryInvalidJitterWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :call_agent, from: :idle, to: :done do
          execute :spec_retry_agent
          retry_on attempts: 2, jitter: "soon"
        end
      end
    end.to raise_error(workflow_error, /jitter/)

    expect do
      with_stubbed_class("SpecRetryInvalidMaxDelayWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :call_agent, from: :idle, to: :done do
          execute :spec_retry_agent
          retry_on attempts: 2, max_delay: -1
        end
      end
    end.to raise_error(workflow_error, /max_delay/)

    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |invalid_delay|
      expect do
        Class.new(workflow_class) do
          initial_state :idle
          state :done
          transition :call_agent, from: :idle, to: :done do
            execute :spec_retry_agent
            retry_on attempts: 2, backoff: invalid_delay
          end
        end
      end.to raise_error(workflow_error, /backoff must be finite and non-negative/)
    end

    expect do
      Class.new(workflow_class) do
        initial_state :idle
        state :done
        transition :call_agent, from: :idle, to: :done do
          execute :spec_retry_agent
          retry_on attempts: 1_000_000
        end
      end
    end.to raise_error(workflow_error, /attempts must not exceed/)
  end

  it "keeps retry jitter inside max_delay" do
    workflow = with_stubbed_class("SpecRetryDelayWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :call_agent, from: :idle, to: :done do
        execute :spec_retry_agent
        retry_on attempts: 2, backoff: 1.0, max_delay: 1.0, jitter: 10.0
      end
    end.new

    allow(workflow).to receive(:rand).and_return(0.75)

    expect(workflow.send(:retry_delay, workflow.class.find_transition(:call_agent).retry_config, 1)).to eq(1.0)
  end

  it "retries through an extreme base delay when the policy supplies a safe cap" do
    attempts = 0
    workflow = Class.new(workflow_class) do
      initial_state :idle
      state :done
      transition :work, from: :idle, to: :done do
        execute :spec_retry_agent
        retry_on Smith::AgentError, attempts: 2, backoff: Float::MAX, max_delay: 0.25
      end
    end.new
    workflow.define_singleton_method(:execute_transition_body) do |_transition, **|
      attempts += 1
      raise Smith::AgentError, "temporary" if attempts == 1

      :recovered
    end
    allow(workflow).to receive(:sleep)

    result = workflow.run!

    expect(result.output).to eq(:recovered)
    expect(attempts).to eq(2)
    expect(workflow).to have_received(:sleep).with(0.25)
  end

  it "revalidates retry policy before transition work begins" do
    original_limit = Smith.config.retry_attempt_limit
    calls = 0
    workflow = Class.new(workflow_class) do
      initial_state :idle
      state :done
      transition :call_agent, from: :idle, to: :done do
        compute { calls += 1 }
        retry_on attempts: 3
      end
    end.new
    Smith.config.retry_attempt_limit = 2

    expect { workflow.run! }.to raise_error(ArgumentError, /attempts must not exceed 2/)
    expect(calls).to eq(0)
  ensure
    Smith.config.retry_attempt_limit = original_limit
  end

  it "counts failed billable retry attempts against workflow budget" do
    error_class = Class.new(StandardError) do
      attr_reader :input_tokens, :output_tokens

      def initialize(message, input_tokens:, output_tokens:)
        super(message)
        @input_tokens = input_tokens
        @output_tokens = output_tokens
      end
    end

    agent = with_stubbed_class("SpecRetryBillableAgent", agent_class) do
      register_as :spec_retry_billable_agent
      model "gpt-5-mini"
    end

    attempts = 0
    allow(agent).to receive(:chat) do
      Object.new.tap do |chat|
        chat.define_singleton_method(:add_message) { |_message| self }
        chat.define_singleton_method(:complete) do
          attempts += 1
          raise error_class.new("billable timeout", input_tokens: 7, output_tokens: 3) if attempts == 1

          Struct.new(:content, :input_tokens, :output_tokens).new("ok", 5, 5)
        end
      end
    end

    workflow = with_stubbed_class("SpecRetryBillableBudgetWorkflow", workflow_class) do
      initial_state :idle
      state :done
      budget total_tokens: 20

      transition :call_agent, from: :idle, to: :done do
        execute :spec_retry_billable_agent
        retry_on Smith::AgentError, attempts: 2
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("ok")
    expect(attempts).to eq(2)
    expect(workflow.ledger.consumed.fetch(:total_tokens)).to eq(20)
    expect(result.usage_entries.map(&:attempt_kind)).to eq(%i[failed_attempt completed_attempt])
  end

  it "exposes retry metadata through graph inspection" do
    workflow = with_stubbed_class("SpecRetryGraphWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :call_agent, from: :idle, to: :done do
        execute :spec_retry_agent
        retry_on Smith::AgentError, attempts: 4, backoff: 0.1, max_delay: 1.0, jitter: 0.01
      end
    end

    transition = workflow.validate_graph.transitions.find { |snapshot| snapshot.name == :call_agent }

    expect(transition.to_h.fetch(:retry_policy)).to eq(
      attempts: 4,
      error_classes: ["Smith::AgentError"],
      backoff: 0.1,
      max_delay: 1.0,
      jitter: 0.01
    )
  end
end
