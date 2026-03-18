# frozen_string_literal: true

RSpec.describe "Smith::Guardrails runtime behavior" do
  let(:guardrails_class) { require_const("Smith::Guardrails") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:guardrail_failed) { require_const("Smith::GuardrailFailed") }

  it "blocks step execution and routes through on_failure when an input guardrail fails" do
    workflow_guardrails = with_stubbed_class("SpecBlockingInputGuardrails", guardrails_class) do
      define_method(:reject_input) { |_payload| raise "bad input" }
      input :reject_input
    end

    with_stubbed_class("SpecBlockingInputAgent", agent_class) do
      register_as :spec_blocking_input_agent
    end

    workflow = with_stubbed_class("SpecBlockingInputWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed
      guardrails workflow_guardrails

      transition :start, from: :idle, to: :running do
        execute :spec_blocking_input_agent
        on_failure :fail
      end
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      @executed = true
      super(_transition, prepared_input: prepared_input)
    end

    result = workflow.run!

    expect(workflow.state).to eq(:failed)
    expect(result.state).to eq(:failed)
    expect(workflow.instance_variable_get(:@executed)).not_to eq(true)
    expect(result.steps.first[:error]).to be_a(guardrail_failed)
  end

  it "routes through on_failure when an output guardrail fails after execution" do
    observed = []

    workflow_guardrails = with_stubbed_class("SpecBlockingOutputGuardrails", guardrails_class) do
      define_method(:reject_output) do |_payload|
        observed << :output_guardrail
        raise "bad output"
      end

      output :reject_output
    end

    with_stubbed_class("SpecBlockingOutputAgent", agent_class) do
      register_as :spec_blocking_output_agent
    end

    workflow = with_stubbed_class("SpecBlockingOutputWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed
      guardrails workflow_guardrails

      transition :start, from: :idle, to: :running do
        execute :spec_blocking_output_agent
        on_failure :fail
      end
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      observed << :executed
      super(_transition, prepared_input: prepared_input)
      :ok
    end

    result = workflow.run!

    expect(workflow.state).to eq(:failed)
    expect(result.state).to eq(:failed)
    expect(observed).to eq(%i[executed output_guardrail])
    expect(result.steps.first[:error]).to be_a(guardrail_failed)
  end

  it "does not emit a success event when a guardrail failure routes the workflow to failure" do
    events = require_const("Smith::Events")
    event_class = require_const("Smith::Event")
    observed = []

    workflow_guardrails = with_stubbed_class("SpecGuardrailEventGuardrails", guardrails_class) do
      define_method(:reject_input) { |_payload| raise "bad input" }
      input :reject_input
    end

    with_stubbed_class("SpecGuardrailEventAgent", agent_class) do
      register_as :spec_guardrail_event_agent
    end

    workflow = with_stubbed_class("SpecGuardrailEventWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed
      guardrails workflow_guardrails

      transition :start, from: :idle, to: :running do
        execute :spec_guardrail_event_agent
        on_failure :fail
      end
    end.new

    events.on(event_class) { |event| observed << event }

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(observed).to eq([])
  end
end
