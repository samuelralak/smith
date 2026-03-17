# frozen_string_literal: true

RSpec.describe "Smith events scoping contract" do
  let(:events) { require_const("Smith::Events") }
  let(:event_class) { require_const("Smith::Event") }

  it "supports filtered subscriptions" do
    typed_event = with_stubbed_class("SpecFilteredEvent", event_class)

    handle = events.on(typed_event, if: ->(event) { event.respond_to?(:workflow_id) }) { |_event| nil }

    expect(handle).to respond_to(:cancel)
  end

  it "yields a scoped subscription object that supports on" do
    yielded_scope = nil

    events.within do |scope|
      yielded_scope = scope
    end

    expect(yielded_scope).to respond_to(:on)
  end
end
