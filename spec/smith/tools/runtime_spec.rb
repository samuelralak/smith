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

  it "denies execution for privilege :authenticated when context[:user] is missing" do
    tool = with_stubbed_class("SpecAuthenticatedPrivilegeTool", tool_class) do
      capabilities do
        privilege :authenticated
      end

      def perform(**_kwargs)
        raise "perform should not be called"
      end
    end.new

    expect do
      tool.execute(context: {}, query: "test")
    end.to raise_error(require_const("Smith::ToolPolicyDenied"), "privilege requires context[:user]")
  end

  it "denies execution for privilege :elevated when context[:role] is not :elevated" do
    tool = with_stubbed_class("SpecElevatedPrivilegeTool", tool_class) do
      capabilities do
        privilege :elevated
      end

      def perform(**_kwargs)
        raise "perform should not be called"
      end
    end.new

    expect do
      tool.execute(context: { user: :ok, role: :admin }, query: "test")
    end.to raise_error(require_const("Smith::ToolPolicyDenied"), "privilege :elevated requires context[:role] == :elevated")
  end

  it "runs authorize after the privilege gate passes" do
    observed = []

    tool = with_stubbed_class("SpecPrivilegeThenAuthorizeTool", tool_class) do
      capabilities do
        privilege :authenticated
      end

      authorize do |context|
        observed << [:authorize, context]
        true
      end

      define_method(:perform) do |**kwargs|
        observed << [:perform, kwargs]
        :ok
      end
    end.new

    result = tool.execute(context: { user: :ok }, query: "test")

    expect(result).to eq(:ok)
    expect(observed).to eq([
                             [:authorize, { user: :ok }],
                             [:perform, { context: { user: :ok }, query: "test" }]
                           ])
  end
end
