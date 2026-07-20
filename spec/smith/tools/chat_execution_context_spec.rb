# frozen_string_literal: true

RSpec.describe "Smith::Tool chat execution context" do
  let(:tool_class) { require_const("Smith::Tool") }
  let(:tool_call_class) { Data.define(:name, :arguments) }

  def chat_class
    Class.new do
      attr_reader :tools

      def initialize(tools)
        @tools = tools
      end

      def run_concurrently(tool_calls)
        execute_tools_concurrently(tool_calls)
      end

      def run_sequentially(tool_call) = execute_tool(tool_call)

      private

      def execute_tool(tool_call)
        tools.fetch(tool_call.name).call(tool_call.arguments)
      end

      def execute_tools_concurrently(tool_calls, &on_result)
        RubyLLM::ToolConcurrency.run(:threads, tool_calls, on_result:) do |tool_call|
          execute_tool(tool_call)
        end
      end
    end
  end

  it "propagates complete context through a Smith chat without patching raw chats" do
    context = Object.new.freeze
    captured = Queue.new
    tool = with_stubbed_class("SpecChatExecutionContextTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| { context_id: result.object_id } }
      def perform(**_kwargs) = self.class.current_invocation_context
    end.new
    raw_chat = chat_class.new(context_tool: tool)
    tool_class.current_tool_result_collector = ->(entry) { captured << entry }
    calls = {
      first: tool_call_class.new(name: :context_tool, arguments: {}),
      second: tool_call_class.new(name: :context_tool, arguments: {})
    }

    chat = Smith::Tool::ChatExecutionContext.install(raw_chat)
    results = tool_class.with_invocation_context(context) do
      chat.run_concurrently(calls)
    end

    expect(results.map(&:last)).to eq([context, context])
    expect(2.times.map { captured.pop.fetch(:captured) }).to all(eq(context_id: context.object_id))
    expect(raw_chat.singleton_class).to be < Smith::Tool::ChatExecutionContext
    expect(chat_class.new({}).singleton_class).not_to be < Smith::Tool::ChatExecutionContext
  ensure
    tool_class.current_tool_result_collector = nil
    tool_class.current_invocation_context = nil
  end

  it "fails closed when RubyLLM no longer exposes the required execution hook" do
    incompatible_chat = Object.new
    incompatible_chat.define_singleton_method(:tools) { {} }

    expect do
      Smith::Tool::ChatExecutionContext.install(incompatible_chat)
    end.to raise_error(Smith::Error, "unsupported RubyLLM chat execution interface: missing #execute_tool")
  end

  it "scopes Smith tools attached after chat construction" do
    context = Object.new.freeze
    tool = with_stubbed_class("SpecLateBoundContextTool", tool_class) do
      def perform(**_kwargs) = self.class.current_invocation_context
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new({}))
    chat.tools[:late] = tool

    result = tool_class.with_invocation_context(context) do
      chat.run_concurrently(only: tool_call_class.new(name: :late, arguments: {}))
    end

    expect(result.sole.last).to equal(context)
  ensure
    tool_class.current_invocation_context = nil
  end

  it "gives strict capture uncertainty precedence over concurrent sibling errors" do
    effects = Queue.new
    capture_tool = with_stubbed_class("SpecConcurrentCaptureFailureTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| result }
      define_method(:perform) do |**_kwargs|
        sleep(0.02)
        effects << :performed
        :captured
      end
    end.new
    failing_tool = with_stubbed_class("SpecConcurrentAgentFailureTool", tool_class) do
      def perform(**_kwargs)
        raise Smith::AgentError, "provider failed first"
      end
    end.new
    tool_class.current_tool_result_collector = ->(_entry) { raise "collector unavailable" }
    raw_chat = chat_class.new(capture: capture_tool, failure: failing_tool)
    chat = Smith::Tool::ChatExecutionContext.install(raw_chat)
    calls = {
      first: tool_call_class.new(name: :failure, arguments: {}),
      second: tool_call_class.new(name: :capture, arguments: {})
    }

    expect { chat.run_concurrently(calls) }.to raise_error(Smith::ToolCaptureFailed) do |error|
      expect(error.reason).to eq(:collector_failed)
    end
    expect(effects.size).to eq(1)
  ensure
    tool_class.current_tool_result_collector = nil
  end

  it "does not replace process-fatal sibling errors with capture uncertainty" do
    capture_tool = with_stubbed_class("SpecFatalSiblingCaptureTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| result }
      def perform(**_kwargs) = :captured
    end.new
    interrupting_tool = with_stubbed_class("SpecInterruptingTool", tool_class) do
      def perform(**_kwargs)
        sleep(0.02)
        raise Interrupt, "shutdown"
      end
    end.new
    tool_class.current_tool_result_collector = ->(_entry) { raise "collector unavailable" }
    chat = Smith::Tool::ChatExecutionContext.install(
      chat_class.new(capture: capture_tool, interrupt: interrupting_tool)
    )
    calls = {
      first: tool_call_class.new(name: :interrupt, arguments: {}),
      second: tool_call_class.new(name: :capture, arguments: {})
    }

    expect { chat.run_concurrently(calls) }.to raise_error(Interrupt, "shutdown")
  ensure
    tool_class.current_tool_result_collector = nil
  end

  it "preserves a fatal sibling that completes before strict capture uncertainty" do
    capture_tool = with_stubbed_class("SpecLateCaptureWithFatalSiblingTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| result }
      def perform(**_kwargs)
        sleep(0.02)
        :captured
      end
    end.new
    interrupting_tool = with_stubbed_class("SpecEarlyInterruptingTool", tool_class) do
      def perform(**_kwargs) = raise(Interrupt, "shutdown")
    end.new
    tool_class.current_tool_result_collector = ->(_entry) { raise "collector unavailable" }
    chat = Smith::Tool::ChatExecutionContext.install(
      chat_class.new(capture: capture_tool, interrupt: interrupting_tool)
    )
    calls = {
      first: tool_call_class.new(name: :interrupt, arguments: {}),
      second: tool_call_class.new(name: :capture, arguments: {})
    }

    expect { chat.run_concurrently(calls) }.to raise_error(Interrupt, "shutdown")
  ensure
    tool_class.current_tool_result_collector = nil
  end

  it "does not replace an escaping callback fatality with queued capture uncertainty" do
    capture_tool = with_stubbed_class("SpecCaptureBeforeCallbackFatalTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| result }
      def perform(**_kwargs) = :captured
    end.new
    fatal_chat_class = Class.new(chat_class) do
      private

      def execute_tools_concurrently(...)
        super
      ensure
        raise Interrupt, "callback shutdown"
      end
    end
    tool_class.current_tool_result_collector = ->(_entry) { raise "collector unavailable" }
    chat = Smith::Tool::ChatExecutionContext.install(fatal_chat_class.new(capture: capture_tool))
    calls = { capture: tool_call_class.new(name: :capture, arguments: {}) }

    expect { chat.run_concurrently(calls) }.to raise_error(Interrupt, "callback shutdown")
  ensure
    tool_class.current_tool_result_collector = nil
  end

  it "isolates capture failures between concurrent batches on one chat" do
    release_capture = Queue.new
    capture_started = Queue.new
    capture_tool = with_stubbed_class("SpecIsolatedBatchCaptureTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| result }
      define_method(:perform) do |**_kwargs|
        capture_started << true
        release_capture.pop
        :captured
      end
    end.new
    failing_tool = with_stubbed_class("SpecIsolatedBatchFailureTool", tool_class) do
      def perform(**_kwargs) = raise(Smith::AgentError, "separate batch failure")
    end.new
    tool_class.current_tool_result_collector = ->(_entry) { raise "collector unavailable" }
    chat = Smith::Tool::ChatExecutionContext.install(
      chat_class.new(capture: capture_tool, failure: failing_tool)
    )
    capture_calls = { capture: tool_call_class.new(name: :capture, arguments: {}) }
    failure_calls = { failure: tool_call_class.new(name: :failure, arguments: {}) }
    capture_context = Smith::Tool::ScopedContext.capture
    capture_batch = Thread.new do
      Smith::Tool::ScopedContext.around(capture_context) { chat.run_concurrently(capture_calls) }
      nil
    rescue StandardError => e
      e
    end
    capture_started.pop

    expect { chat.run_concurrently(failure_calls) }.to raise_error(Smith::AgentError, "separate batch failure")
    release_capture << true
    expect(capture_batch.value).to be_a(Smith::ToolCaptureFailed)
  ensure
    release_capture << true if capture_batch&.alive?
    capture_batch&.join
    tool_class.current_tool_result_collector = nil
  end

  it "captures invocation context per execution instead of retaining a stale chat snapshot" do
    first_context = Object.new.freeze
    second_context = Object.new.freeze
    tool = with_stubbed_class("SpecReusedChatContextTool", tool_class) do
      def perform(**_kwargs) = self.class.current_invocation_context
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = tool_call_class.new(name: :probe, arguments: {})

    first = tool_class.with_invocation_context(first_context) { chat.run_concurrently(only: call) }
    second = tool_class.with_invocation_context(second_context) { chat.run_concurrently(only: call) }
    absent = chat.run_sequentially(call)

    expect(first.sole.last).to equal(first_context)
    expect(second.sole.last).to equal(second_context)
    expect(absent).to be_nil
    expect(tool_class.current_invocation_context).to be_nil
  ensure
    tool_class.current_invocation_context = nil
  end
end
