# frozen_string_literal: true

RSpec.describe "Smith::Tool runtime behavior" do
  let(:tool_class) { require_const("Smith::Tool") }
  let(:deadline_exceeded) { require_const("Smith::DeadlineExceeded") }
  let(:tool_capture_failed) { require_const("Smith::ToolCaptureFailed") }

  it "scopes opaque host invocation context and restores nested values" do
    outer = Object.new
    inner = Object.new
    tool_class.current_invocation_context = outer

    observed = tool_class.with_invocation_context(inner) do
      [tool_class.current_invocation_context, :result]
    end

    expect(observed).to eq([inner, :result])
    expect(tool_class.current_invocation_context).to equal(outer)
  ensure
    tool_class.current_invocation_context = nil
  end

  it "restores invocation context when the scoped operation raises" do
    outer = Object.new
    tool_class.current_invocation_context = outer

    expect do
      tool_class.with_invocation_context(Object.new) { raise "boom" }
    end.to raise_error(RuntimeError, "boom")

    expect(tool_class.current_invocation_context).to equal(outer)
  ensure
    tool_class.current_invocation_context = nil
  end

  it "rejects an incomplete scoped context before mutating current values" do
    outer = Object.new
    tool_class.current_guardrails = outer

    expect do
      Smith::Tool::ScopedContext.around(current_guardrails: :inner) { nil }
    end.to raise_error(ArgumentError, "tool context must contain the complete scoped context")

    expect(tool_class.current_guardrails).to equal(outer)
  ensure
    tool_class.current_guardrails = nil
  end

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

  it "fails strict capture when the capture block raises" do
    tool_class.current_tool_result_collector = proc {}
    tool = with_stubbed_class("SpecStrictBadCaptureTool", tool_class) do
      capture_result(strict: true) { raise "capture boom" }
      def perform(**_kwargs) = "success"
    end.new

    expect { tool.execute }.to raise_error(tool_capture_failed) do |error|
      expect(error.reason).to eq(:capture_block_failed)
      expect(error.cause).to be_a(RuntimeError)
    end
  ensure
    tool_class.current_tool_result_collector = nil
  end

  it "fails strict capture when no collector is active" do
    performed = []
    tool_class.current_tool_result_collector = nil
    tool = with_stubbed_class("SpecStrictNoCollectorTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| { data: result } }
      define_method(:perform) do |**_kwargs|
        performed << true
        "success"
      end
    end.new

    expect { tool.execute }.to raise_error(tool_capture_failed) do |error|
      expect(error.reason).to eq(:collector_missing)
      expect(error.cause).to be_nil
    end
    expect(performed).to be_empty
  end

  it "fails strict capture before host hooks when no collector is active" do
    observed = []
    tool_class.current_tool_result_collector = nil
    tool = with_stubbed_class("SpecStrictPreflightHookTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| { data: result } }
      before_execute { |_tool, _kwargs| observed << :hook }
      define_method(:perform) { |**_kwargs| observed << :perform }
    end.new

    expect { tool.execute }.to raise_error(tool_capture_failed) do |error|
      expect(error.reason).to eq(:collector_missing)
    end
    expect(observed).to be_empty
  end

  it "fails strict capture before perform when the collector is not callable" do
    performed = []
    tool_class.current_tool_result_collector = Object.new
    tool = with_stubbed_class("SpecStrictInvalidCollectorTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| { data: result } }
      define_method(:perform) { |**_kwargs| performed << true }
    end.new

    expect { tool.execute }.to raise_error(tool_capture_failed) do |error|
      expect(error.reason).to eq(:collector_invalid)
    end
    expect(performed).to be_empty
  ensure
    tool_class.current_tool_result_collector = nil
  end

  it "fails strict capture when the capture is empty" do
    tool_class.current_tool_result_collector = proc {}
    tool = with_stubbed_class("SpecStrictEmptyCaptureTool", tool_class) do
      capture_result(strict: true) { nil }
      def perform(**_kwargs) = "success"
    end.new

    expect { tool.execute }.to raise_error(tool_capture_failed) do |error|
      expect(error.reason).to eq(:capture_empty)
    end
  ensure
    tool_class.current_tool_result_collector = nil
  end

  it "captures false as valid strict evidence" do
    captured = []
    tool_class.current_tool_result_collector = ->(entry) { captured << entry }
    tool = with_stubbed_class("SpecStrictFalseCaptureTool", tool_class) do
      capture_result(strict: true) { false }
      def perform(**_kwargs) = "success"
    end.new

    expect(tool.execute).to eq("success")
    expect(captured.sole.fetch(:captured)).to be(false)
  ensure
    tool_class.current_tool_result_collector = nil
  end

  it "accepts nil or false collector returns as successful delivery" do
    tool = with_stubbed_class("SpecStrictCollectorReturnTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| { data: result } }
      def perform(**_kwargs) = "success"
    end.new

    [nil, false].each do |collector_return|
      tool_class.current_tool_result_collector = ->(_entry) { collector_return }
      expect(tool.execute).to eq("success")
    end
  ensure
    tool_class.current_tool_result_collector = nil
  end

  it "keeps capture opt-in per concrete subclass" do
    captured = []
    tool_class.current_tool_result_collector = ->(entry) { captured << entry }
    parent = with_stubbed_class("SpecStrictCaptureParentTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| { inherited: result } }
      def perform(**_kwargs) = "parent-result"
    end
    child = Class.new(parent)

    expect(child.capture_result).to be_nil
    expect(child.capture_result_strict?).to be(false)
    expect(child.new.execute).to eq("parent-result")
    expect(captured).to be_empty
  ensure
    tool_class.current_tool_result_collector = nil
  end

  it "rejects a non-boolean strict capture policy" do
    expect do
      with_stubbed_class("SpecInvalidStrictCaptureTool", tool_class) do
        capture_result(strict: :yes) { true }
      end
    end.to raise_error(ArgumentError, "capture_result strict must be true or false")
  end

  it "fails strict capture when the collector raises" do
    tool_class.current_tool_result_collector = ->(_entry) { raise "collector boom" }
    tool = with_stubbed_class("SpecStrictBadCollectorTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| { data: result } }
      def perform(**_kwargs) = "success"
    end.new

    expect { tool.execute }.to raise_error(tool_capture_failed) do |error|
      expect(error.reason).to eq(:collector_failed)
      expect(error.cause).to be_a(RuntimeError)
    end
  ensure
    tool_class.current_tool_result_collector = nil
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
