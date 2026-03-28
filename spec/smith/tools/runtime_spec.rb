# frozen_string_literal: true

RSpec.describe "Smith::Tool runtime behavior" do
  let(:tool_class) { require_const("Smith::Tool") }
  let(:deadline_exceeded) { require_const("Smith::DeadlineExceeded") }

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

  it "denies tool execution before perform when the cooperative wall_clock deadline is exceeded" do
    observed = []

    tool = with_stubbed_class("SpecDeadlineTool", tool_class) do
      define_method(:perform) do |**_kwargs|
        observed << :perform
        :ok
      end
    end.new

    tool_class.current_deadline = Time.now.utc - 1

    expect do
      tool.execute(context: { user: :ok }, query: "test")
    end.to raise_error(deadline_exceeded, "wall_clock deadline exceeded during tool execution")

    expect(observed).to eq([])
  ensure
    tool_class.current_deadline = nil
  end

  it "appends captured data to active collector when capture_result is configured" do
    captured = []
    collector = ->(entry) { captured << entry }
    tool_class.current_tool_result_collector = collector

    tool = with_stubbed_class("SpecCaptureTool", tool_class) do
      capture_result do |_kwargs, result|
        { url: "https://example.com", content: result.to_s }
      end

      def perform(**_kwargs)
        "search results"
      end
    end.new

    tool.execute
    expect(captured.length).to eq(1)
    expect(captured.first[:tool]).to be_a(String)
    expect(captured.first[:captured][:url]).to eq("https://example.com")
  ensure
    tool_class.current_tool_result_collector = nil
  end

  it "does not append when capture_result is not configured" do
    captured = []
    tool_class.current_tool_result_collector = ->(entry) { captured << entry }

    tool = with_stubbed_class("SpecNoCaptTool", tool_class) do
      def perform(**_kwargs)
        "result"
      end
    end.new

    tool.execute
    expect(captured).to be_empty
  ensure
    tool_class.current_tool_result_collector = nil
  end

  it "logs and does not fail tool execution when capture_result raises" do
    captured = []
    tool_class.current_tool_result_collector = ->(entry) { captured << entry }
    logger = instance_double(Logger, warn: nil)
    original_logger = Smith.config.logger
    Smith.configure { |c| c.logger = logger }

    tool = with_stubbed_class("SpecBadCapTool", tool_class) do
      capture_result { |_kwargs, _result| raise "capture boom" }

      def perform(**_kwargs)
        "success"
      end
    end.new

    result = tool.execute
    expect(result).to eq("success")
    expect(captured).to be_empty
    expect(logger).to have_received(:warn).with(/capture_result failed/)
  ensure
    tool_class.current_tool_result_collector = nil
    Smith.configure { |c| c.logger = original_logger }
  end

  it "skips capture silently when no collector is active" do
    tool_class.current_tool_result_collector = nil

    tool = with_stubbed_class("SpecNoCollTool", tool_class) do
      capture_result { |_kwargs, result| { data: result } }

      def perform(**_kwargs)
        "result"
      end
    end.new

    result = tool.execute
    expect(result).to eq("result")
  end
end
