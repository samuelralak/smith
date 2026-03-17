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
end
