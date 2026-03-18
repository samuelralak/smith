# frozen_string_literal: true

RSpec.describe "Smith::Tool failure policy contract" do
  let(:tool_class) { require_const("Smith::Tool") }

  it "raises ToolPolicyDenied when authorization fails" do
    tool = with_stubbed_class("SpecDeniedTool", tool_class) do
      category :action
      authorize { |_context| false }

      def perform(**kwargs)
        kwargs
      end
    end.new

    expect do
      tool.execute(context: { user: nil }, query: "test")
    end.to raise_error(require_const("Smith::ToolPolicyDenied"))
  end

  it "does not enforce approval metadata without a host hook" do
    tool = with_stubbed_class("SpecApprovalTool", tool_class) do
      category :action

      capabilities do
        approval :required
      end

      def perform(**kwargs)
        kwargs
      end
    end.new

    expect(tool.execute(context: { user: nil }, query: "test")).to include(query: "test")
  end

  it "allows a pre-dispatch hook to deny execution with ToolPolicyDenied" do
    policy_denied = require_const("Smith::ToolPolicyDenied")

    tool = with_stubbed_class("SpecHookDeniedTool", tool_class) do
      category :action

      capabilities do
        approval :required
      end

      before_execute do |_tool, _kwargs|
        raise policy_denied, "approval required"
      end

      def perform(**_kwargs)
        raise "perform should not run"
      end
    end.new

    expect do
      tool.execute(context: { user: :ok }, query: "test")
    end.to raise_error(policy_denied, "approval required")
  end
end
