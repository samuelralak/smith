# frozen_string_literal: true

RSpec.describe "Smith::Tool contract" do
  let(:tool_class) { require_const("Smith::Tool") }

  it "extends RubyLLM::Tool" do
    expect(tool_class).to be < RubyLLM::Tool
  end

  it "provides the documented policy DSL" do
    %i[category capabilities authorize].each do |dsl|
      expect(tool_class).to respond_to(dsl), "expected Smith::Tool to implement .#{dsl}"
    end
  end

  it "expects tool authors to define perform rather than execute" do
    concrete = with_stubbed_class("SpecPaymentTool", tool_class) do
      category :action
      authorize { true }

      def perform(amount:, idempotency_key:)
        { amount:, idempotency_key: }
      end
    end

    expect(concrete.instance_methods(false)).to include(:perform)
  end
end
