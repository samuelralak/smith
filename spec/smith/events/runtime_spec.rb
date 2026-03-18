# frozen_string_literal: true

RSpec.describe "Smith events runtime contract" do
  let(:events) { require_const("Smith::Events") }
  let(:event_class) { require_const("Smith::Event") }
  let(:step_completed_class) { require_const("Smith::Events::StepCompleted") }
  let(:workflow_class) { require_const("Smith::Workflow") }

  before do
    events.reset! if events.respond_to?(:reset!)
  end

  it "auto-cancels scoped subscriptions when the block exits" do
    handle = nil
    typed_event = with_stubbed_class("SpecScopedEvent", event_class)

    events.within do |scope|
      handle = scope.on(typed_event) { |_event| nil }
      expect(handle.cancelled?).to be(false)
    end

    expect(handle.cancelled?).to be(true)
  end

  it "retains the filter predicate on a subscription" do
    typed_event = with_stubbed_class("SpecPredicateEvent", event_class)
    predicate = ->(event) { event.execution_id.start_with?("x") }

    handle = events.on(typed_event, if: predicate) { |_event| nil }

    expect(handle.predicate).to be(predicate)
  end

  it "marks a subscription as cancelled when the handle is cancelled" do
    typed_event = with_stubbed_class("SpecCancellableEvent", event_class)

    handle = events.on(typed_event) { |_event| nil }
    expect(handle.cancelled?).to be(false)

    handle.cancel

    expect(handle.cancelled?).to be(true)
  end

  it "retains subscriptions in registration order" do
    first_event = with_stubbed_class("SpecFirstOrderedEvent", event_class)
    second_event = with_stubbed_class("SpecSecondOrderedEvent", event_class)

    first = events.on(first_event) { |_event| nil }
    second = events.on(second_event) { |_event| nil }

    expect(events.subscriptions.last(2)).to eq([first, second])
  end

  it "reset! clears all registered subscriptions" do
    typed_event = with_stubbed_class("SpecResettableEvent", event_class)

    events.on(typed_event) { |_event| nil }
    expect(events.subscriptions).not_to be_empty

    events.reset!

    expect(events.subscriptions).to eq([])
  end

  it "dispatches matching handlers in subscription order" do
    typed_event = with_stubbed_class("SpecOrderedDispatchEvent", event_class)
    observed = []

    events.on(typed_event) { |_event| observed << :first }
    events.on(typed_event) { |_event| observed << :second }

    events.emit(typed_event.new(execution_id: "exec-1", trace_id: "trace-1"))

    expect(observed).to eq(%i[first second])
  end

  it "dispatches only to matching event classes and predicates" do
    typed_event = with_stubbed_class("SpecFilteredDispatchEvent", event_class)
    other_event = with_stubbed_class("SpecIgnoredDispatchEvent", event_class)
    observed = []

    events.on(typed_event, if: ->(event) { event.execution_id == "match" }) { |event| observed << event.execution_id }
    events.on(other_event) { |_event| observed << :wrong_class }

    events.emit(typed_event.new(execution_id: "skip", trace_id: "trace-1"))
    events.emit(typed_event.new(execution_id: "match", trace_id: "trace-2"))

    expect(observed).to eq(["match"])
  end

  it "rescues and logs handler failures without aborting the dispatch" do
    typed_event = with_stubbed_class("SpecRescuedEvent", event_class)
    logger = instance_double("Logger")
    observed = []
    original_logger = Smith.config.logger

    allow(logger).to receive(:error)
    Smith.configure { |config| config.logger = logger }

    events.on(typed_event) { |_event| raise "boom" }
    events.on(typed_event) { |_event| observed << :ran }

    expect do
      events.emit(typed_event.new(execution_id: "exec-1", trace_id: "trace-1"))
    end.not_to raise_error

    expect(observed).to eq([:ran])
    expect(logger).to have_received(:error).with(/Smith::Events handler error: boom/)
  ensure
    Smith.configure { |config| config.logger = original_logger }
  end

  it "emits a workflow event after a successful workflow step completes" do
    observed = []
    workflow = with_stubbed_class("SpecWorkflowEventSuccessWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end.new

    events.on(event_class) { |event| observed << event }

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(observed.length).to eq(1)
    expect(observed.first).to be_a(step_completed_class)
    expect(observed.first.execution_id).to be_a(String)
    expect(observed.first.trace_id).to be_a(String)
    expect(observed.first.transition).to eq(:finish)
    expect(observed.first.from).to eq(:idle)
    expect(observed.first.to).to eq(:done)
  end

  it "allows typed subscribers and base-event subscribers to observe the same workflow step event" do
    base_observed = []
    typed_observed = []

    workflow = with_stubbed_class("SpecWorkflowTypedEventWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end.new

    events.on(event_class) { |event| base_observed << event }
    events.on(step_completed_class) { |event| typed_observed << event }

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(base_observed.length).to eq(1)
    expect(typed_observed.length).to eq(1)
    expect(base_observed.first).to be_a(step_completed_class)
    expect(typed_observed.first).to be_a(step_completed_class)
    expect(base_observed.first.transition).to eq(:finish)
    expect(typed_observed.first.transition).to eq(:finish)
  end

  it "does not emit a workflow event when a workflow step fails" do
    observed = []
    workflow = with_stubbed_class("SpecWorkflowEventFailureWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed

      transition :start, from: :idle, to: :running do
        execute :spec_event_agent
        on_failure :fail
      end
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      raise Smith::WorkflowError, "step failed"
    end

    events.on(event_class) { |event| observed << event }

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(observed).to eq([])
  end
end
