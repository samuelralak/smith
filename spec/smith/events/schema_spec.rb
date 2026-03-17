# frozen_string_literal: true

RSpec.describe "Smith event schema contract" do
  let(:event_class) { require_const("Smith::Event") }

  it "supports the documented event attribute DSL" do
    expect(event_class).to respond_to(:attribute)
  end

  it "allows a typed event schema to be declared with inherited correlation fields" do
    typed_event = with_stubbed_class("SpecTypedEvent", event_class) do
      attribute :workflow_id, require_const("Smith::Types::String")
      attribute :branch_count, require_const("Smith::Types::Integer")
    end

    expect(typed_event).to be < event_class
    expect(typed_event.instance_methods).to include(:execution_id, :trace_id)
  end
end
