# frozen_string_literal: true

RSpec.describe "Smith events contract" do
  let(:events) { require_const("Smith::Events") }
  let(:event_class) { require_const("Smith::Event") }

  it "provides a typed event base and a scoped subscription API" do
    expect(event_class).not_to be_nil
    expect(events).to respond_to(:on)
    expect(events).to respond_to(:within)
  end

  it "returns a cancellable subscription handle" do
    typed_event = with_stubbed_class("SpecBranchingCompleted", event_class)

    handle = events.on(typed_event) { |_event| nil }
    expect(handle).to respond_to(:cancel)
  end
end
