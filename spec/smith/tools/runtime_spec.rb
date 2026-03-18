# frozen_string_literal: true

RSpec.describe "Smith::Tool runtime behavior" do
  let(:tool_class) { require_const("Smith::Tool") }

  it "delegates execute to perform after Smith-owned enforcement" do
    tool = with_stubbed_class("SpecDelegatingTool", tool_class) do
      category :action
      authorize { true }

      def perform(**kwargs)
        kwargs
      end
    end.new

    result = tool.execute(context: { user: :ok }, amount: 10, idempotency_key: "abc-123")

    expect(result).to eq(context: { user: :ok }, amount: 10, idempotency_key: "abc-123")
  end

  it "passes the provided context into the authorization block" do
    seen_context = nil

    tool = with_stubbed_class("SpecContextAwareTool", tool_class) do
      category :action
      authorize do |context|
        seen_context = context
        true
      end

      def perform(**kwargs)
        kwargs
      end
    end.new

    context = { user: :ok, role: :admin }
    tool.execute(context: context, query: "test")

    expect(seen_context).to eq(context)
  end

  it "does not call perform when authorization fails" do
    tool = with_stubbed_class("SpecNonExecutingDeniedTool", tool_class) do
      category :action
      authorize { |_context| false }

      def perform(**_kwargs)
        raise "perform should not be called"
      end
    end.new

    expect do
      tool.execute(context: { user: nil }, query: "test")
    end.to raise_error(require_const("Smith::ToolPolicyDenied"))
  end
end
