# frozen_string_literal: true

RSpec.describe "Smith::Tool chat execution context" do
  let(:tool_class) { require_const("Smith::Tool") }
  let(:tool_call_class) { Data.define(:name, :arguments) }

  def chat_class = SpecToolExecutionChat

  def no_op_failure_handler = ->(request:, error:) { request && error }

  def bounded_chat(tool, responses)
    context = RubyLLM.context do |config|
      config.openai_api_key = "test"
      config.tool_concurrency = :threads
    end
    chat = SpecBoundedRubyLLMChat.new(responses:, context:).with_tool(tool)
    Smith::Tool::ChatExecutionContext.install(chat)
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

  it "requires a terminal failure callback when durable batch admission is configured" do
    expect do
      tool_class.with_invocation_context(Object.new, batch_admitter: ->(requests:) { requests }) { nil }
    end.to raise_error(
      ArgumentError,
      "invocation failure handler is required when a batch admitter is configured"
    )
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
    sibling_failed = Queue.new
    capture_tool = with_stubbed_class("SpecConcurrentCaptureFailureTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| result }
      define_method(:perform) do |**_kwargs|
        raise "sibling failure barrier timed out" unless sibling_failed.pop(timeout: 5)

        effects << :performed
        :captured
      end
    end.new
    failing_tool = with_stubbed_class("SpecConcurrentAgentFailureTool", tool_class) do
      define_method(:perform) do |**_kwargs|
        sibling_failed << true
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
    capture_started = Queue.new
    capture_tool = with_stubbed_class("SpecFatalSiblingCaptureTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| result }
      def perform(**_kwargs) = :captured
    end.new
    interrupting_tool = with_stubbed_class("SpecInterruptingTool", tool_class) do
      define_method(:perform) do |**_kwargs|
        raise "capture barrier timed out" unless capture_started.pop(timeout: 5)

        raise Interrupt, "shutdown"
      end
    end.new
    tool_class.current_tool_result_collector = lambda do |_entry|
      capture_started << true
      raise "collector unavailable"
    end
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
    sibling_interrupted = Queue.new
    capture_tool = with_stubbed_class("SpecLateCaptureWithFatalSiblingTool", tool_class) do
      capture_result(strict: true) { |_kwargs, result| result }
      define_method(:perform) do |**_kwargs|
        raise "interrupt barrier timed out" unless sibling_interrupted.pop(timeout: 5)

        :captured
      end
    end.new
    interrupting_tool = with_stubbed_class("SpecEarlyInterruptingTool", tool_class) do
      define_method(:perform) do |**_kwargs|
        sibling_interrupted << true
        raise(Interrupt, "shutdown")
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

  it "exposes normalized call identity and deterministic batch order to concurrent Smith tools" do
    context = Object.new.freeze
    tool = with_stubbed_class("SpecInvocationMetadataTool", tool_class) do
      def perform(**_kwargs) = self.class.current_invocation
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call_class = RubyLLM::ToolCall
    calls = {
      first: call_class.new(id: "call-1", name: :probe, arguments: {}),
      second: call_class.new(id: "call-2", name: :probe, arguments: {})
    }

    invocations = tool_class.with_invocation_context(context) do
      chat.run_concurrently(calls).map(&:last).sort_by(&:ordinal)
    end

    expect(invocations.map(&:to_h)).to eq([
                                            {
                                              tool_call_id: "call-1",
                                              tool_name: "probe",
                                              ordinal: 1,
                                              batch_ordinal: 1,
                                              batch_size: 2
                                            },
                                            {
                                              tool_call_id: "call-2",
                                              tool_name: "probe",
                                              ordinal: 2,
                                              batch_ordinal: 2,
                                              batch_size: 2
                                            }
                                          ])
    expect(tool_class.current_invocation).to be_nil
  ensure
    tool_class.current_invocation_context = nil
  end

  it "admits the complete invocation batch before dispatching any tool" do
    effects = []
    tool = with_stubbed_class("SpecAtomicBatchAdmissionTool", tool_class) do
      define_method(:perform) do |value:|
        effects << [:performed, value]
        value
      end
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call_class = RubyLLM::ToolCall
    calls = {
      first: call_class.new(id: "batch-1", name: :probe, arguments: { value: "first" }),
      second: call_class.new(id: "batch-2", name: :probe, arguments: { value: "second" })
    }
    admitter = lambda do |requests:|
      effects << [:admitted, requests.map { _1.invocation.tool_call_id }]
      expect(requests.map(&:tool_class)).to eq([tool.class, tool.class])
      expect(requests.map(&:arguments)).to eq([{ value: "first" }, { value: "second" }])
    end

    tool_class.with_invocation_context(
      Object.new.freeze,
      batch_admitter: admitter,
      failure_handler: no_op_failure_handler
    ) do
      chat.run_sequential_batch(calls)
    end

    expect(effects).to eq([
                            [:admitted, %w[batch-1 batch-2]],
                            [:performed, "first"],
                            [:performed, "second"]
                          ])
  end

  it "admits only Smith tools while preserving plain RubyLLM calls in a mixed provider batch" do
    admitted = []
    executions = []
    smith_tool = with_stubbed_class("SpecMixedBatchSmithTool", tool_class) do
      define_method(:perform) do |value:|
        executions << [:smith, value]
        value
      end
    end.new
    plain_tool = Class.new(RubyLLM::Tool) do
      define_method(:name) { "plain_probe" }
      define_method(:execute) do |value:|
        executions << [:plain, value]
        value
      end
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(
      chat_class.new(spec_mixed_batch_smith: smith_tool, plain_probe: plain_tool)
    )
    call_class = RubyLLM::ToolCall
    mixed_calls = {
      smith: call_class.new(
        id: "smith-1",
        name: :spec_mixed_batch_smith,
        arguments: { value: "smith" }
      ),
      plain: call_class.new(id: "plain-1", name: :plain_probe, arguments: { value: "plain" })
    }
    next_call = {
      smith: call_class.new(
        id: "smith-2",
        name: :spec_mixed_batch_smith,
        arguments: { value: "next" }
      )
    }
    admitter = ->(requests:) { admitted.concat(requests) }

    tool_class.with_invocation_context(
      Object.new.freeze,
      batch_admitter: admitter,
      failure_handler: no_op_failure_handler
    ) do
      chat.run_sequential_batch(mixed_calls)
      chat.run_sequential_batch(next_call)
    end

    expect(executions).to eq([[:smith, "smith"], [:plain, "plain"], [:smith, "next"]])
    expect(admitted.map { _1.invocation.tool_call_id }).to eq(%w[smith-1 smith-2])
    expect(admitted.map { _1.invocation.ordinal }).to eq([1, 2])
    expect(admitted.map { _1.invocation.batch_size }).to eq([1, 1])
  end

  it "dispatches no tool when host batch admission fails" do
    performed = false
    failures = []
    tool = with_stubbed_class("SpecRejectedBatchAdmissionTool", tool_class) do
      define_method(:perform) do |**|
        performed = true
      end
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(id: "rejected", name: :probe, arguments: {})
    admitter = ->(requests:) { raise Smith::Error, "host rejected #{requests.length} calls" }

    expect do
      tool_class.with_invocation_context(
        Object.new.freeze,
        batch_admitter: admitter,
        failure_handler: ->(request:, error:) { failures << [request, error] }
      ) do
        chat.run_sequential_batch(only: call)
      end
    end.to raise_error(Smith::Error, "host rejected 1 calls")
    expect(performed).to be(false)
    expect(failures).to be_empty
  end

  it "dispatches the admitted argument snapshot when the source call changes" do
    executions = []
    failures = []
    tool = with_stubbed_class("SpecImmutableAdmissionArgumentsTool", tool_class) do
      define_method(:perform) { |value:| executions << value }
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(id: "immutable", name: :probe, arguments: { value: "original" })
    admitter = ->(requests:) { requests.sole.invocation && call.arguments[:value] = "mutated" }
    failure_handler = ->(request:, error:) { failures << [request, error] }

    tool_class.with_invocation_context(Object.new.freeze, batch_admitter: admitter, failure_handler:) do
      chat.run_sequential_batch(only: call)
    end

    expect(executions).to eq(["original"])
    expect(failures).to be_empty
  end

  it "does not let pre-execution hooks mutate admitted arguments" do
    executions = []
    hook_error = nil
    tool = with_stubbed_class("SpecImmutableHookArgumentsTool", tool_class) do
      before_execute do |_tool, arguments|
        arguments[:value] = "mutated"
      rescue FrozenError => e
        hook_error = e
      end
      define_method(:perform) do |value:|
        executions << value
        value
      end
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(id: "immutable-hook", name: :probe, arguments: { value: "admitted" })

    result = chat.run_sequential_batch(only: call)

    expect(result).to eq(["admitted"])
    expect(hook_error).to be_a(FrozenError)
    expect(executions).to eq(["admitted"])
  end

  it "does not let pre-execution hooks mutate nested admitted arguments" do
    executions = []
    hook_error = nil
    tool = with_stubbed_class("SpecImmutableNestedHookArgumentsTool", tool_class) do
      before_execute do |_tool, arguments|
        arguments.fetch(:payload)[:value] = "mutated"
      rescue FrozenError => e
        hook_error = e
      end
      define_method(:perform) { |payload:| executions << payload.fetch(:value) }
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(
      id: "immutable-nested-hook",
      name: :probe,
      arguments: { payload: { value: "admitted" } }
    )

    chat.run_sequential_batch(only: call)

    expect(hook_error).to be_a(FrozenError)
    expect(executions).to eq(["admitted"])
  end

  it "keeps admitted provider identity when the source call id changes" do
    executions = []
    failures = []
    tool = with_stubbed_class("SpecImmutableAdmissionCallIdTool", tool_class) do
      define_method(:perform) { |**| executions << :performed }
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(id: "original-id", name: :probe, arguments: {})
    admitter = lambda do |requests:|
      requests.sole
      call.instance_variable_set(:@id, "mutated-id")
    end
    failure_handler = ->(request:, error:) { failures << [request, error] }

    tool_class.with_invocation_context(Object.new.freeze, batch_admitter: admitter, failure_handler:) do
      chat.run_sequential_batch(only: call)
    end

    expect(executions).to eq([:performed])
    expect(failures).to be_empty
  end

  it "executes exactly the calls in the admitted batch when the source collection changes" do
    executions = []
    tool = with_stubbed_class("SpecImmutableAdmissionMembershipTool", tool_class) do
      define_method(:perform) { |value:| executions << value }
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    second_call = RubyLLM::ToolCall.new(id: "second", name: :probe, arguments: { value: "second" })
    calls = {
      first: RubyLLM::ToolCall.new(id: "first", name: :probe, arguments: { value: "first" }),
      second: second_call
    }
    admitter = lambda do |requests:|
      expect(requests.map { _1.invocation.tool_call_id }).to eq(%w[first second])
      calls.delete(:second)
      calls[:third] = RubyLLM::ToolCall.new(id: "third", name: :probe, arguments: { value: "third" })
    end

    tool_class.with_invocation_context(
      Object.new.freeze,
      batch_admitter: admitter,
      failure_handler: no_op_failure_handler
    ) { chat.run_sequential_batch(calls) }
    chat.run_sequential_batch(reused: second_call)

    expect(executions).to eq(%w[first second second])
  end

  it "does not invoke provider argument equality after admission" do
    hostile_arguments = Class.new(Hash) do
      def ==(_other) = raise("provider equality must not run after admission")
    end.new
    hostile_arguments[:value] = "stable"
    executions = []
    tool = with_stubbed_class("SpecEqualityIndependentAdmissionTool", tool_class) do
      define_method(:perform) { |value:| executions << value }
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(id: "hostile-equality", name: :probe, arguments: hostile_arguments)

    tool_class.with_invocation_context(
      Object.new.freeze,
      batch_admitter: ->(requests:) { expect(requests.sole.arguments).to eq(value: "stable") },
      failure_handler: no_op_failure_handler
    ) { chat.run_sequential_batch(only: call) }

    expect(executions).to eq(["stable"])
  end

  it "rejects retained source-call execution before host admission" do
    executions = []
    failures = []
    tool = with_stubbed_class("SpecPrematureSourceDispatchTool", tool_class) do
      define_method(:perform) do |value:|
        executions << value
        value
      end
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(id: "premature", name: :probe, arguments: { value: "original" })
    admitter = ->(requests:) { requests.sole && chat.run_sequentially(call) }

    expect do
      tool_class.with_invocation_context(
        Object.new.freeze,
        batch_admitter: admitter,
        failure_handler: ->(request:, error:) { failures << [request, error] }
      ) { chat.run_sequential_batch(only: call) }
    end.to raise_error(Smith::ToolDispatchRejected)

    expect(executions).to be_empty
    expect(failures).to be_empty
    expect(chat.run_sequential_batch(reused: call)).to eq(["original"])
  end

  it "releases registry ownership when reservation settlement fails" do
    executions = []
    reservation = Class.new do
      define_method(:claim) { true }
      def settle! = raise("settlement failed")
    end.new
    allowance = Class.new(Smith::Tool::CallAllowance) do
      define_method(:reserve_batch) { |_calls, **| reservation }
    end.new(2)
    tool = with_stubbed_class("SpecSettlementFailureTool", tool_class) do
      define_method(:perform) do |value:|
        executions << value
        value
      end
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(id: "settlement", name: :probe, arguments: { value: "once" })
    tool_class.current_tool_call_allowance = allowance

    expect { chat.run_sequential_batch(only: call) }.to raise_error(RuntimeError, "settlement failed")

    tool_class.current_tool_call_allowance = nil
    expect(chat.run_sequential_batch(reused: call)).to eq(["once"])
    expect(executions).to eq(%w[once once])
  ensure
    tool_class.current_tool_call_allowance = nil
  end

  it "does not replace a process-fatal execution error when settlement also fails" do
    reservation = Class.new do
      define_method(:claim) { true }
      def settle! = raise("settlement failed")
    end.new
    allowance = Class.new(Smith::Tool::CallAllowance) do
      define_method(:reserve_batch) { |_calls, **| reservation }
    end.new(1)
    tool = with_stubbed_class("SpecFatalSettlementFailureTool", tool_class) do
      def perform(**) = raise(Interrupt, "shutdown")
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(id: "fatal-settlement", name: :probe, arguments: {})
    tool_class.current_tool_call_allowance = allowance

    expect { chat.run_sequential_batch(only: call) }.to raise_error(Interrupt, "shutdown")
  ensure
    tool_class.current_tool_call_allowance = nil
  end

  it "does not let a logger failure replace a process-fatal execution error" do
    reservation = Class.new do
      define_method(:claim) { true }
      def settle! = raise("settlement failed")
    end.new
    allowance = Class.new(Smith::Tool::CallAllowance) do
      define_method(:reserve_batch) { |_calls, **| reservation }
    end.new(1)
    logger = Class.new do
      def error(*) = raise("logger failed")
    end.new
    tool = with_stubbed_class("SpecFatalLoggerFailureTool", tool_class) do
      def perform(**) = raise(Interrupt, "shutdown")
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(id: "fatal-logger", name: :probe, arguments: {})
    previous_logger = Smith.config.logger
    Smith.config.logger = logger
    tool_class.current_tool_call_allowance = allowance

    expect { chat.run_sequential_batch(only: call) }.to raise_error(Interrupt, "shutdown")
  ensure
    Smith.config.logger = previous_logger
    tool_class.current_tool_call_allowance = nil
  end

  it "leaves admitted receipts unsettled for host recovery after process-fatal interruption" do
    failures = []
    tool = with_stubbed_class("SpecAdmittedInterruptTool", tool_class) do
      def perform(**) = raise(Interrupt, "shutdown")
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(id: "admitted-interrupt", name: :probe, arguments: {})

    expect do
      tool_class.with_invocation_context(
        Object.new.freeze,
        batch_admitter: ->(requests:) { requests.sole },
        failure_handler: ->(request:, error:) { failures << [request, error] }
      ) { chat.run_sequential_batch(only: call) }
    end.to raise_error(Interrupt, "shutdown")
    expect(failures).to be_empty
  end

  it "reads mutable provider call metadata once at the batch boundary" do
    executions = []
    provider_call = Class.new do
      attr_reader :arguments, :name_reads

      def initialize
        @arguments = { value: "stable" }
        @name_reads = 0
      end

      def id = "single-read"

      def name
        @name_reads += 1
        @name_reads == 1 ? :probe : :wrong_tool
      end
    end.new
    tool = with_stubbed_class("SpecSingleReadMetadataTool", tool_class) do
      define_method(:perform) { |value:| executions << value }
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))

    chat.run_sequential_batch(only: provider_call)

    expect(provider_call.name_reads).to eq(1)
    expect(executions).to eq(["stable"])
  end

  it "preserves source-call identity and mutability for RubyLLM callbacks" do
    executions = []
    tool = with_stubbed_class("SpecCallbackSourceIdentityTool", tool_class) do
      define_method(:perform) do |value:|
        executions << value
        value
      end
    end.new
    source_call = RubyLLM::ToolCall.new(id: "callback", name: tool.name.to_sym, arguments: { value: "stable" })
    responses = [
      RubyLLM::Message.new(role: :assistant, content: nil, tool_calls: { only: source_call }),
      RubyLLM::Message.new(role: :assistant, content: "done", tool_calls: {})
    ]
    allowance = Smith::Tool::CallAllowance.new(1, on_exhaustion: :complete)
    tool_class.current_tool_call_allowance = allowance
    chat = bounded_chat(tool, responses)
    observed = nil
    chat.before_tool_call do |tool_call|
      observed = tool_call
      tool_call.thought_signature = "callback-owned"
    end

    result = chat.complete

    expect(result.content).to eq("done")
    expect(observed).to equal(source_call)
    expect(source_call.thought_signature).to eq("callback-owned")
    expect(executions).to eq(["stable"])
  ensure
    tool_class.current_tool_call_allowance = nil
  end

  it "preserves callback process fatalities over an earlier ordinary error" do
    first_tool = with_stubbed_class("SpecCallbackOrdinaryFailureTool", tool_class) do
      def perform(**) = raise(Smith::AgentError, "ordinary")
    end.new
    fatal_tool = with_stubbed_class("SpecCallbackFatalityTool", tool_class) do
      def perform(**) = raise("must not reach perform")
    end.new
    callback_chat_class = Class.new(chat_class) do
      def before_tool_call(&block) = @before_tool_call = block

      private

      def execute_tool_with_callbacks(tool_call)
        @before_tool_call&.call(tool_call)
        execute_tool(tool_call)
      end

      def execute_tools_concurrently(tool_calls, **)
        errors = tool_calls.each_value.filter_map do |tool_call|
          execute_tool_with_callbacks(tool_call)
          nil
        rescue Exception => e # rubocop:disable Lint/RescueException
          e
        end
        raise errors.first if errors.any?
      end
    end
    chat = Smith::Tool::ChatExecutionContext.install(
      callback_chat_class.new(first: first_tool, fatal: fatal_tool)
    )
    chat.before_tool_call { |call| raise Interrupt, "shutdown" if call.name.to_sym == :fatal }
    calls = {
      first: RubyLLM::ToolCall.new(id: "ordinary", name: :first, arguments: {}),
      fatal: RubyLLM::ToolCall.new(id: "fatal", name: :fatal, arguments: {})
    }

    expect { chat.run_concurrently(calls) }.to raise_error(Interrupt, "shutdown")
  end

  it "rejects an admitted invocation when its registered tool changes before dispatch" do
    executions = []
    original = with_stubbed_class("SpecImmutableAdmissionTool", tool_class) do
      define_method(:perform) { |**| executions << :original }
    end.new
    replacement = with_stubbed_class("SpecReplacementAdmissionTool", tool_class) do
      define_method(:perform) { |**| executions << :replacement }
    end.new
    raw_chat = chat_class.new(probe: original)
    chat = Smith::Tool::ChatExecutionContext.install(raw_chat)
    call = RubyLLM::ToolCall.new(id: "stable-tool", name: :probe, arguments: {})
    admitter = ->(requests:) { requests.sole && raw_chat.tools[:probe] = replacement }

    expect do
      tool_class.with_invocation_context(
        Object.new.freeze,
        batch_admitter: admitter,
        failure_handler: no_op_failure_handler
      ) do
        chat.run_sequential_batch(only: call)
      end
    end.to raise_error(Smith::ToolDispatchRejected, "admitted tool invocation changed before dispatch")
    expect(executions).to be_empty
  end

  it "rejects duplicate provider call identity before host admission" do
    admitted = false
    tool = with_stubbed_class("SpecDuplicateProviderCallTool", tool_class) do
      def perform(**) = :unused
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(id: "duplicate", name: :probe, arguments: {})

    expect do
      tool_class.with_invocation_context(
        Object.new.freeze,
        batch_admitter: ->(requests:) { admitted = requests.any? },
        failure_handler: no_op_failure_handler
      ) do
        chat.run_sequential_batch(first: call, second: call)
      end
    end.to raise_error(Smith::Error, "tool call appears more than once in one provider batch")
    expect(admitted).to be(false)
  end

  it "rejects an oversized fail-fast batch before host admission" do
    admitted = false
    executions = []
    tool = with_stubbed_class("SpecFailFastBatchBudgetTool", tool_class) do
      define_method(:perform) { |value:| executions << value }
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call_class = RubyLLM::ToolCall
    calls = {
      first: call_class.new(id: "budget-1", name: :probe, arguments: { value: 1 }),
      second: call_class.new(id: "budget-2", name: :probe, arguments: { value: 2 })
    }

    expect do
      tool_class.with_call_budget(1) do
        tool_class.with_invocation_context(
          Object.new.freeze,
          batch_admitter: ->(requests:) { admitted = requests.any? },
          failure_handler: no_op_failure_handler
        ) { chat.run_sequential_batch(calls) }
      end
    end.to raise_error(Smith::BudgetExceeded, "agent tool_calls budget exceeded")
    expect(admitted).to be(false)
    expect(executions).to be_empty
  end

  it "rejects aggregate batch bytes before host admission" do
    admitted = false
    executed = false
    tool = with_stubbed_class("SpecAggregateBatchBytesTool", tool_class) do
      define_method(:perform) { |**| executed = true }
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    payload = "x" * 600_000
    calls = {
      first: RubyLLM::ToolCall.new(id: "bytes-1", name: :probe, arguments: { value: payload }),
      second: RubyLLM::ToolCall.new(id: "bytes-2", name: :probe, arguments: { value: payload }),
      third: RubyLLM::ToolCall.new(id: "bytes-3", name: :probe, arguments: { value: payload })
    }
    allow(Smith::Tool::InvocationRequest).to receive(:new).and_call_original

    expect do
      tool_class.with_invocation_context(
        Object.new.freeze,
        batch_admitter: ->(requests:) { admitted = requests.any? },
        failure_handler: no_op_failure_handler
      ) { chat.run_sequential_batch(calls) }
    end.to raise_error(Smith::Error, /tool batch arguments exceed .* bytes/)
    expect(Smith::Tool::InvocationRequest).to have_received(:new).twice
    expect(admitted).to be(false)
    expect(executed).to be(false)
  end

  it "rejects excessive Smith tool-call cardinality before snapshot allocation" do
    tool = with_stubbed_class("SpecExcessiveBatchCardinalityTool", tool_class) do
      def perform(**) = :unused
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    limit = Smith::Tool::ExecutionBatchRequests::MAX_CALLS
    calls = (limit + 1).times.to_h do |index|
      id = "call-#{index}"
      [id, RubyLLM::ToolCall.new(id:, name: :probe, arguments: {})]
    end
    allow(Smith::Tool::InvocationRequest).to receive(:new).and_call_original

    expect do
      tool_class.with_invocation_context(
        Object.new.freeze,
        batch_admitter: ->(requests:) { requests },
        failure_handler: no_op_failure_handler
      ) { chat.run_sequential_batch(calls) }
    end.to raise_error(Smith::Error, "provider tool batch must contain between 1 and #{limit} calls")
    expect(Smith::Tool::InvocationRequest).not_to have_received(:new)
  end

  it "bounds total provider call cardinality even when calls are unavailable" do
    limit = Smith::Tool::ExecutionBatchCollection::MAX_CALLS
    calls = (limit + 1).times.to_h do |index|
      [index, RubyLLM::ToolCall.new(id: "missing-#{index}", name: :missing, arguments: {})]
    end
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new({}))

    expect do
      chat.run_sequential_batch(calls)
    end.to raise_error(Smith::Error, "provider tool batch must contain between 1 and #{limit} calls")
  end

  it "bounds provider call metadata before host admission" do
    admitted = false
    tool = with_stubbed_class("SpecBoundedProviderMetadataTool", tool_class) do
      def perform(**) = raise("must not execute")
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(
      id: "x" * (Smith::Tool::ExecutionBatchSourceCall::MAX_METADATA_BYTES + 1),
      name: :probe,
      arguments: {}
    )

    expect do
      tool_class.with_invocation_context(
        Object.new.freeze,
        batch_admitter: ->(requests:) { admitted = requests.any? },
        failure_handler: no_op_failure_handler
      ) { chat.run_sequential_batch(only: call) }
    end.to raise_error(Smith::Error, /tool call id exceeds .* bytes/)
    expect(admitted).to be(false)
  end

  it "stops provider metadata capture as soon as the aggregate bound is crossed" do
    signature = "s" * 220_000
    calls = 4.times.to_h do |index|
      id = "metadata-#{index}"
      [id, RubyLLM::ToolCall.new(id:, name: :missing, arguments: {}, thought_signature: signature)]
    end
    crossing = Class.new do
      attr_reader :id, :name, :thought_signature

      def initialize(signature)
        @id = "metadata-crossing"
        @name = :missing
        @thought_signature = signature
      end

      def arguments = raise("crossing call arguments must not be read")
    end.new(signature)
    calls[:crossing] = crossing
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new({}))

    expect do
      chat.run_sequential_batch(calls)
    end.to raise_error(Smith::Error, /provider tool batch metadata exceeds/)
  end

  it "rejects aggregate batch values before host admission" do
    admitted = false
    executed = false
    tool = with_stubbed_class("SpecAggregateBatchValuesTool", tool_class) do
      define_method(:perform) { |**| executed = true }
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    values = Array.new(50_000)
    calls = {
      first: RubyLLM::ToolCall.new(id: "values-1", name: :probe, arguments: { values: values }),
      second: RubyLLM::ToolCall.new(id: "values-2", name: :probe, arguments: { values: values })
    }

    expect do
      tool_class.with_invocation_context(
        Object.new.freeze,
        batch_admitter: ->(requests:) { admitted = requests.any? },
        failure_handler: no_op_failure_handler
      ) { chat.run_sequential_batch(calls) }
    end.to raise_error(Smith::Error, /tool batch arguments exceed .* values/)
    expect(admitted).to be(false)
    expect(executed).to be(false)
  end

  it "notifies the host when an admitted invocation fails during Smith dispatch" do
    failures = []
    tool = with_stubbed_class("SpecInvocationFailureNotificationTool", tool_class) do
      def perform(**) = raise(Smith::DeadlineExceeded, "deadline reached")
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(id: "failed", name: :probe, arguments: {})
    failure_handler = ->(request:, error:) { failures << [request, error] }

    expect do
      tool_class.with_invocation_context(
        Object.new.freeze,
        batch_admitter: ->(requests:) { expect(requests.length).to eq(1) },
        failure_handler:
      ) do
        chat.run_sequential_batch(only: call)
      end
    end.to raise_error(Smith::DeadlineExceeded, "deadline reached")
    expect(failures.length).to eq(1)
    expect(failures.sole.first.invocation.tool_call_id).to eq("failed")
    expect(failures.sole.last).to be_a(Smith::DeadlineExceeded)
  end

  it "classifies an admitted pre-dispatch hook rejection without marking external work uncertain" do
    failures = []
    performed = false
    tool = with_stubbed_class("SpecPredispatchFailureNotificationTool", tool_class) do
      before_execute { raise "local policy unavailable" }
      define_method(:perform) { |**| performed = true }
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call = RubyLLM::ToolCall.new(id: "pre-dispatch", name: :probe, arguments: {})

    expect do
      tool_class.with_invocation_context(
        Object.new.freeze,
        batch_admitter: ->(requests:) { expect(requests.length).to eq(1) },
        failure_handler: ->(request:, error:) { failures << [request, error] }
      ) { chat.run_sequential_batch(only: call) }
    end.to raise_error(RuntimeError, "local policy unavailable")
    expect(performed).to be(false)
    expect(failures.sole.first.invocation.tool_call_id).to eq("pre-dispatch")
    expect(failures.sole.last).to be_a(Smith::ToolDispatchRejected)
  end

  it "does not let a failed host notification strand admitted siblings" do
    notifications = []
    attempts = Hash.new(0)
    failing_tool = with_stubbed_class("SpecRetriedFailureNotificationTool", tool_class) do
      def perform(**) = raise(Smith::DeadlineExceeded, "deadline reached")
    end.new
    sibling_tool = with_stubbed_class("SpecUnstartedFailureNotificationTool", tool_class) do
      def perform(**) = raise("must not execute after the first failure")
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(
      chat_class.new(failing: failing_tool, sibling: sibling_tool)
    )
    calls = {
      first: RubyLLM::ToolCall.new(id: "failed-first", name: :failing, arguments: {}),
      second: RubyLLM::ToolCall.new(id: "unstarted-second", name: :sibling, arguments: {})
    }
    failure_handler = lambda do |request:, error:|
      call_id = request.invocation.tool_call_id
      attempts[call_id] += 1
      notifications << [call_id, error.class]
      raise "receipt store unavailable" if call_id == "failed-first" && attempts[call_id] == 1
    end

    matcher = raise_error(Smith::ToolFailureNotificationFailed) do |error|
      expect(error.notification_error.message).to eq("receipt store unavailable")
    end
    expect do
      tool_class.with_invocation_context(
        Object.new.freeze,
        batch_admitter: ->(requests:) { expect(requests.length).to eq(2) },
        failure_handler:
      ) { chat.run_sequential_batch(calls) }
    end.to matcher
    expect(attempts).to eq("failed-first" => 1, "unstarted-second" => 1)
    expect(notifications).to include(
      ["failed-first", Smith::DeadlineExceeded],
      ["unstarted-second", Smith::ToolDispatchRejected]
    )
  end

  it "does not let a failed unsettled notification mask a process-fatal sibling error" do
    ordinary_failed = Queue.new
    fatal_tool = with_stubbed_class("SpecFatalAfterOrdinaryFailureTool", tool_class) do
      define_method(:perform) do |**_kwargs|
        raise "ordinary failure barrier timed out" unless ordinary_failed.pop(timeout: 5)

        raise NoMemoryError, "allocation failed"
      end
    end.new
    failing_tool = with_stubbed_class("SpecOrdinaryFailureBeforeFatalTool", tool_class) do
      define_method(:perform) do |**_kwargs|
        ordinary_failed << true
        raise Smith::DeadlineExceeded, "deadline reached"
      end
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(
      chat_class.new(failing: failing_tool, fatal: fatal_tool)
    )
    calls = {
      first: RubyLLM::ToolCall.new(id: "ordinary-first", name: :failing, arguments: {}),
      second: RubyLLM::ToolCall.new(id: "fatal-second", name: :fatal, arguments: {})
    }
    failure_handler = lambda do |request:, error:|
      raise "receipt store unavailable for #{request.invocation.tool_call_id} after #{error.class}"
    end

    expect do
      tool_class.with_invocation_context(
        Object.new.freeze,
        batch_admitter: ->(requests:) { expect(requests.length).to eq(2) },
        failure_handler:
      ) { chat.run_concurrently(calls) }
    end.to raise_error(NoMemoryError, "allocation failed")
  end

  it "shares one invocation sequence across chats in the same execution scope" do
    context = Object.new.freeze
    tool = with_stubbed_class("SpecInvocationSequenceContextTool", tool_class) do
      def perform(**_kwargs) = self.class.current_invocation.ordinal
    end.new
    first_chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    second_chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call_class = RubyLLM::ToolCall
    call = ->(id) { { only: call_class.new(id:, name: :probe, arguments: {}) } }

    ordinals = tool_class.with_invocation_context(context) do
      [
        first_chat.run_sequential_batch(call.call("first")).sole,
        second_chat.run_sequential_batch(call.call("second")).sole
      ]
    end

    expect(ordinals).to eq([1, 2])
  ensure
    tool_class.current_invocation_context = nil
  end

  it "uses a host-supplied sequence for a resumed execution scope" do
    context = Object.new.freeze
    sequence = Smith::Tool::InvocationSequence.new(next_ordinal: 9)
    tool = with_stubbed_class("SpecResumedInvocationSequenceTool", tool_class) do
      def perform(**_kwargs) = self.class.current_invocation.ordinal
    end.new
    chat = Smith::Tool::ChatExecutionContext.install(chat_class.new(probe: tool))
    call_class = RubyLLM::ToolCall

    ordinal = tool_class.with_invocation_context(context, invocation_sequence: sequence) do
      chat.run_sequential_batch(only: call_class.new(id: "resumed", name: :probe, arguments: {})).sole
    end

    expect(ordinal).to eq(9)
    expect(tool_class.current_invocation).to be_nil
  end

  it "propagates invocation metadata without leaking between fiber executions" do
    context = Object.new.freeze
    tool = with_stubbed_class("SpecFiberInvocationMetadataTool", tool_class) do
      def perform(**_kwargs)
        [self.class.current_invocation_context, self.class.current_invocation]
      end
    end.new
    fiber_chat_class = Class.new(chat_class) do
      private

      def execute_tools_concurrently(tool_calls, **)
        fibers = tool_calls.map do |key, tool_call|
          [key, Fiber.new { execute_tool(tool_call) }]
        end
        fibers.map { |key, fiber| [key, fiber.resume] }
      end
    end
    chat = Smith::Tool::ChatExecutionContext.install(fiber_chat_class.new(probe: tool))
    call_class = RubyLLM::ToolCall
    calls = {
      first: call_class.new(id: "fiber-1", name: :probe, arguments: {}),
      second: call_class.new(id: "fiber-2", name: :probe, arguments: {})
    }

    results = tool_class.with_invocation_context(context) { chat.run_concurrently(calls) }
    observed = results.map(&:last).sort_by { |(_, invocation)| invocation.ordinal }

    expect(observed.map(&:first)).to eq([context, context])
    expect(observed.map { |(_, invocation)| invocation.tool_call_id }).to eq(%w[fiber-1 fiber-2])
    expect(observed.map { |(_, invocation)| invocation.ordinal }).to eq([1, 2])
    expect(tool_class.current_invocation).to be_nil
  ensure
    tool_class.current_invocation_context = nil
  end

  it "completes from captured results after the exact tool allowance is used" do
    executions = []
    tool = with_stubbed_class("SpecBoundedCompletionTool", tool_class) do
      define_method(:perform) do |value:|
        executions << value
        { value: value }
      end
    end.new
    call_class = RubyLLM::ToolCall
    tool_name = tool.name.to_sym
    responses = [
      RubyLLM::Message.new(
        role: :assistant,
        content: nil,
        tool_calls: { first: call_class.new(id: "call-1", name: tool_name, arguments: { value: 1 }) },
        input_tokens: 2,
        output_tokens: 1
      ),
      RubyLLM::Message.new(
        role: :assistant,
        content: nil,
        tool_calls: { second: call_class.new(id: "call-2", name: tool_name, arguments: { value: 2 }) },
        input_tokens: 3,
        output_tokens: 1
      ),
      RubyLLM::Message.new(
        role: :assistant,
        content: "final answer",
        tool_calls: {},
        input_tokens: 4,
        output_tokens: 2
      )
    ]
    allowance = Smith::Tool::CallAllowance.new(2, on_exhaustion: :complete)
    tool_class.current_tool_call_allowance = allowance
    chat = bounded_chat(tool, responses)
    chat.tool_prefs[:calls] = :many

    result = chat.complete

    expect(result.content).to eq("final answer")
    expect(executions).to eq([1, 2])
    expect(allowance.remaining).to eq(0)
    expect(chat.provider_snapshots.map { _1.fetch(:tools) }).to eq([
                                                                     [tool_name], [tool_name], []
                                                                   ])
    expect(chat.provider_snapshots.first.dig(:tool_prefs, :calls)).to eq(:many)
    expect(chat.provider_snapshots.last.dig(:tool_prefs, :choice)).to eq(:none)
    expect(chat.tools.keys).to eq([tool_name])
    expect(chat.tool_prefs).to eq(choice: nil, calls: :many)
    expect(chat.concurrency).to eq(:threads)
    expect(chat.messages.count { _1.role == :tool }).to eq(2)
  ensure
    tool_class.current_tool_call_allowance = nil
  end

  it "rejects an oversized provider batch before executing any sibling" do
    executions = []
    tool = with_stubbed_class("SpecOversizedBatchTool", tool_class) do
      define_method(:perform) do |value:|
        executions << value
        value
      end
    end.new
    call_class = RubyLLM::ToolCall
    tool_name = tool.name.to_sym
    responses = [
      RubyLLM::Message.new(
        role: :assistant,
        content: nil,
        tool_calls: {
          first: call_class.new(id: "call-1", name: tool_name, arguments: { value: 1 }),
          second: call_class.new(id: "call-2", name: tool_name, arguments: { value: 2 })
        },
        input_tokens: 2,
        output_tokens: 1
      ),
      RubyLLM::Message.new(
        role: :assistant,
        content: "limited answer",
        tool_calls: {},
        input_tokens: 3,
        output_tokens: 2
      )
    ]
    allowance = Smith::Tool::CallAllowance.new(1, on_exhaustion: :complete)
    tool_class.current_tool_call_allowance = allowance
    chat = bounded_chat(tool, responses)

    result = chat.complete

    expect(result.content).to eq("limited answer")
    expect(executions).to be_empty
    expect(allowance.remaining).to eq(1)
    expect(chat.messages.count { _1.role == :tool }).to eq(2)
    expect(chat.messages.select { _1.role == :tool }).to all(
      satisfy { |message| message.content.include?("tool_call_budget_exhausted") }
    )
    expect(chat.provider_snapshots.last.fetch(:tools)).to be_empty
  ensure
    tool_class.current_tool_call_allowance = nil
  end

  it "pairs an invalid tool request during finalization before failing" do
    tool = with_stubbed_class("SpecFinalizationViolationTool", tool_class) do
      def perform(**) = raise("must not execute")
    end.new
    call_class = RubyLLM::ToolCall
    tool_name = tool.name.to_sym
    responses = [
      RubyLLM::Message.new(
        role: :assistant,
        content: nil,
        tool_calls: {
          invalid: call_class.new(id: "call-final", name: tool_name, arguments: {})
        },
        input_tokens: 2,
        output_tokens: 1
      )
    ]
    allowance = Smith::Tool::CallAllowance.new(0, on_exhaustion: :complete)
    tool_class.current_tool_call_allowance = allowance
    chat = bounded_chat(tool, responses)

    expect { chat.complete }.to raise_error(
      Smith::BoundedCompletionError,
      "provider requested a tool during tool-disabled budget finalization"
    )
    expect(chat.messages.count { _1.role == :tool }).to eq(1)
    expect(chat.tools.keys).to eq([tool_name])
    expect(chat.tool_prefs).to eq(choice: nil, calls: nil)
  ensure
    tool_class.current_tool_call_allowance = nil
  end
end
