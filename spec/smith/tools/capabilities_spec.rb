# frozen_string_literal: true

RSpec.describe "Smith::Tool capability metadata contract" do
  let(:tool_class) { require_const("Smith::Tool") }

  it "allows capability metadata to be declared in the documented shape" do
    concrete = with_stubbed_class("SpecCapabilityTool", tool_class) do
      category :data_access

      capabilities do
        sensitivity :high
        privilege :elevated
        network :internal
        approval :required
        data_volume :unbounded
      end

      def perform(query:)
        { query: }
      end
    end

    expect(concrete).to be < tool_class
  end
end
