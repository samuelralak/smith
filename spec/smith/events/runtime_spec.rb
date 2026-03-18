# frozen_string_literal: true

RSpec.describe "Smith events runtime contract" do
  let(:events) { require_const("Smith::Events") }
  let(:event_class) { require_const("Smith::Event") }

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
end
