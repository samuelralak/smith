# frozen_string_literal: true

RSpec.describe Smith::Tool::BoundedCompletionContext do
  it "releases completion ownership when interrupted during admission" do
    guard = Smith::Tool::BoundedCompletionGuard.new
    entered = Queue.new
    release = Queue.new
    allow(guard).to receive(:enter).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs)
      entered << true
      release.pop
    end
    owner = Object.new
    thread = Thread.new { guard.around_completion(owner, reentrant: false) { :unreachable } }
    thread.report_on_exception = false
    entered.pop

    thread.raise(Interrupt)
    release << true

    expect { thread.value }.to raise_error(Interrupt)
    allow(guard).to receive(:enter).and_call_original
    expect { guard.around_completion(Object.new, reentrant: false) { :ok } }.not_to raise_error
  end

  def build_response(content: nil, tool_calls: {}, input_tokens: 1, output_tokens: 1)
    RubyLLM::Message.new(
      role: :assistant,
      content: content,
      tool_calls: tool_calls,
      input_tokens: input_tokens,
      output_tokens: output_tokens
    )
  end

  def build_tool_call(id:, name:, arguments:)
    RubyLLM::ToolCall.new(id: id, name: name, arguments: arguments)
  end

  def build_chat(responses:, instrumentation:)
    context = RubyLLM.context do |config|
      config.openai_api_key = "test"
      config.tool_concurrency = :threads
      config.instrumenter = SpecInstrumentationCollector.new(instrumentation)
    end

    chat = SpecBoundedRubyLLMChat.new(responses: responses, context: context)
    Smith::Tool::ChatExecutionContext.install(chat)
  end

  def with_allowance(limit, &block)
    Smith::Tool.current_tool_call_allowance = Smith::Tool::CallAllowance.new(limit, on_exhaustion: :complete)
    Smith::Tool.current_tool_execution_tracker = Smith::Tool::ExecutionTracker.new
    block.call(Smith::Tool.current_tool_call_allowance)
  ensure
    Smith::Tool.current_tool_call_allowance = nil
    Smith::Tool.current_tool_execution_tracker = nil
  end

  def with_fail_fast_allowance(limit, &block)
    Smith::Tool.current_tool_call_allowance = Smith::Tool::CallAllowance.new(limit)
    Smith::Tool.current_tool_execution_tracker = Smith::Tool::ExecutionTracker.new
    block.call(Smith::Tool.current_tool_call_allowance)
  ensure
    Smith::Tool.current_tool_call_allowance = nil
    Smith::Tool.current_tool_execution_tracker = nil
  end

  it "permits only one execution when a tool callback reenters the admitted call" do
    executions = []
    tool = with_stubbed_class("SpecReentrantDispatchTool", Smith::Tool) do
      define_method(:perform) { |value:| executions << value }
    end.new
    call = build_tool_call(id: "reentrant", name: tool.name.to_sym, arguments: { value: "once" })
    chat = build_chat(
      responses: [
        build_response(tool_calls: { "reentrant" => call }),
        build_response(content: "done")
      ],
      instrumentation: []
    ).with_tool(tool)
    reentered = false
    chat.before_tool_call do |source_call|
      next if reentered

      reentered = true
      expect do
        chat.__send__(:execute_tool_with_callbacks, source_call)
      end.to raise_error(Smith::ToolDispatchRejected, "admitted tool invocation was already claimed")
    end

    with_allowance(1) { chat.complete }

    expect(executions).to eq(["once"])
  end

  it "rejects direct Smith tool execution from an admitted callback" do
    executions = []
    failures = []
    tool = with_stubbed_class("SpecDirectCallbackTool", Smith::Tool) do
      define_method(:perform) { |value:| executions << value }
    end.new
    call = build_tool_call(id: "direct-callback", name: tool.name.to_sym, arguments: { value: "admitted" })
    chat = build_chat(
      responses: [
        build_response(tool_calls: { "direct-callback" => call }),
        build_response(content: "done")
      ],
      instrumentation: []
    ).with_tool(tool)
    chat.before_tool_call do
      expect do
        tool.execute(value: "duplicate")
      end.to raise_error(Smith::ToolExecutionNotAdmitted, /exact admitted dispatch authority/)
    end

    Smith::Tool.with_invocation_context(
      Object.new.freeze,
      batch_admitter: ->(requests:) { requests.sole },
      failure_handler: ->(request:, error:) { failures << [request, error] }
    ) do
      with_allowance(2) { chat.complete }
    end

    expect(executions).to eq(["admitted"])
    expect(failures).to be_empty
  end

  it "claims admitted execution authority before pre-execution hooks can reenter" do
    executions = []
    blocked = 0
    reentered = false
    tool = with_stubbed_class("SpecPreExecutionReentryTool", Smith::Tool) do
      before_execute do |instance, _arguments|
        next if reentered

        reentered = true
        begin
          instance.execute(value: "substituted")
        rescue Smith::ToolExecutionNotAdmitted
          blocked += 1
        end
      end
      define_method(:perform) { |value:| executions << value }
    end.new
    call = build_tool_call(id: "pre-execution", name: tool.name.to_sym, arguments: { value: "admitted" })
    chat = build_chat(
      responses: [
        build_response(tool_calls: { "pre-execution" => call }),
        build_response(content: "done")
      ],
      instrumentation: []
    ).with_tool(tool)

    with_allowance(1) { chat.complete }

    expect(executions).to eq(["admitted"])
    expect(blocked).to eq(1)
  end

  it "rejects nested Smith tool execution under an outer admitted receipt" do
    executions = []
    failures = []
    inner = with_stubbed_class("SpecNestedInnerTool", Smith::Tool) do
      define_method(:perform) { executions << :inner }
    end.new
    outer = with_stubbed_class("SpecNestedOuterTool", Smith::Tool) do
      define_method(:perform) do
        executions << :outer
        inner.execute
      end
    end.new
    call = build_tool_call(id: "nested-outer", name: outer.name.to_sym, arguments: {})
    chat = build_chat(
      responses: [build_response(tool_calls: { "nested-outer" => call })],
      instrumentation: []
    ).with_tool(outer)

    expect do
      Smith::Tool.with_invocation_context(
        Object.new.freeze,
        batch_admitter: ->(requests:) { requests.sole },
        failure_handler: ->(request:, error:) { failures << [request, error] }
      ) do
        with_fail_fast_allowance(2) { chat.complete }
      end
    end.to raise_error(Smith::ToolExecutionNotAdmitted, /exact admitted dispatch authority/)

    expect(executions).to eq([:outer])
    expect(failures.length).to eq(1)
    expect(failures.sole.last).to be_a(Smith::ToolExecutionNotAdmitted)
  end

  it "completes a real RubyLLM tool loop at the exact budget" do
    executions = []
    tool = with_stubbed_class("SpecRealBoundedTool", Smith::Tool) do
      define_method(:perform) do |value:|
        executions << value
        { value: value }
      end
    end.new
    instrumentation = []
    responses = [
      build_response(tool_calls: {
                       "call-1" => build_tool_call(id: "call-1", name: :spec_real_bounded, arguments: { value: 1 })
                     }),
      build_response(tool_calls: {
                       "call-2" => build_tool_call(id: "call-2", name: :spec_real_bounded, arguments: { value: 2 })
                     }),
      build_response(content: "final answer")
    ]
    chat = build_chat(responses: responses, instrumentation: instrumentation).with_tool(tool)

    result = with_allowance(2) { chat.complete }

    expect(result.content).to eq("final answer")
    expect(executions).to eq([1, 2])
    expect(chat.messages.select(&:tool_result?).map(&:tool_call_id)).to eq(%w[call-1 call-2])
    active_snapshot = {
      tools: [:spec_real_bounded],
      tool_prefs: { choice: nil, calls: nil },
      concurrency: nil
    }
    final_snapshot = {
      tools: [],
      tool_prefs: { choice: :none, calls: nil },
      concurrency: :threads
    }
    active_instrumentation = { tools: [:spec_real_bounded], tool_choice: nil, tool_call_limit: nil }
    final_instrumentation = { tools: [], tool_choice: :none, tool_call_limit: nil }

    expect(chat.provider_snapshots).to eq([active_snapshot, active_snapshot, final_snapshot])
    expect(instrumentation.map { _2.slice(:tools, :tool_choice, :tool_call_limit) }).to eq(
      [active_instrumentation, active_instrumentation, final_instrumentation]
    )
    expect(chat.tools.keys).to eq([:spec_real_bounded])
    expect(chat.tool_prefs).to eq(choice: nil, calls: nil)
    expect(chat.concurrency).to eq(:threads)
  end

  it "admits a provider batch within the remaining allowance" do
    executions = []
    tool = with_stubbed_class("SpecRealBatchedTool", Smith::Tool) do
      define_method(:perform) do |value:|
        executions << value
        value
      end
    end.new
    chat = build_chat(
      responses: [
        build_response(tool_calls: {
                         "call-1" => build_tool_call(id: "call-1", name: :spec_real_batched,
                                                     arguments: { value: 1 }),
                         "call-2" => build_tool_call(id: "call-2", name: :spec_real_batched,
                                                     arguments: { value: 2 })
                       }),
        build_response(content: "batched answer")
      ],
      instrumentation: []
    ).with_tool(tool).with_params(openai_api_mode: :responses)

    result = with_allowance(2) { chat.complete }

    expect(result.content).to eq("batched answer")
    expect(executions).to eq([1, 2])
    expect(chat.provider_snapshots.map { _1.fetch(:tool_prefs).fetch(:calls) }).to eq(%i[many one])
  end

  it "captures provider membership once without invoking collection overrides" do
    executions = []
    tool = with_stubbed_class("SpecMutatingBoundedBatchTool", Smith::Tool) do
      define_method(:perform) do |value:|
        executions << value
        value
      end
    end.new
    calls_class = Class.new(Hash) do
      attr_accessor :injected_call

      def to_a
        self["injected"] = injected_call
        super
      end
    end
    calls = calls_class.new
    calls["original"] = build_tool_call(
      id: "original",
      name: :spec_mutating_bounded_batch,
      arguments: { value: "original" }
    )
    calls.injected_call = build_tool_call(
      id: "injected",
      name: :spec_mutating_bounded_batch,
      arguments: { value: "injected" }
    )
    chat = build_chat(
      responses: [
        build_response(tool_calls: calls),
        build_response(content: "captured")
      ],
      instrumentation: []
    ).with_tool(tool)

    result = nil
    with_allowance(2) do |allowance|
      result = chat.complete
      expect(allowance.remaining).to eq(1)
    end
    expect(result.content).to eq("captured")
    expect(executions).to eq(["original"])
    expect(calls).not_to have_key("injected")
  end

  it "keeps every provider response intact at the RubyLLM instrumentation boundary" do
    tool = with_stubbed_class("SpecInstrumentedBoundedTool", Smith::Tool) do
      define_method(:perform) { |value:| value }
    end.new
    instrumentation = []
    chat = build_chat(
      responses: [
        build_response(tool_calls: {
                         "call-1" => build_tool_call(id: "call-1", name: :spec_instrumented_bounded,
                                                     arguments: { value: 1 })
                       }),
        build_response(content: "instrumented answer")
      ],
      instrumentation:
    ).with_tool(tool)

    result = with_allowance(1) { chat.complete }

    expect(result.content).to eq("instrumented answer")
    expect(instrumentation.map { _2.fetch(:response) }).to all(be_a(RubyLLM::Message))
    expect(instrumentation.map { _2.fetch(:input_tokens) }).to eq([1, 1])
    expect(instrumentation.map { _2.fetch(:output_tokens) }).to eq([1, 1])
  end

  it "uses the single-call provider hint when the selected endpoint supports it" do
    tool = with_stubbed_class("SpecResponsesBoundedTool", Smith::Tool) do
      define_method(:perform) { |value:| value }
    end.new
    chat = build_chat(
      responses: [
        build_response(tool_calls: {
                         "call-1" => build_tool_call(id: "call-1", name: :spec_responses_bounded,
                                                     arguments: { value: 1 })
                       }),
        build_response(content: "done")
      ],
      instrumentation: []
    ).with_tool(tool).with_params(openai_api_mode: :responses)

    result = with_allowance(1) { chat.complete }

    expect(result.content).to eq("done")
    expect(chat.provider_snapshots.first.fetch(:tool_prefs)).to eq(choice: nil, calls: :one)
    expect(chat.provider_snapshots.last.fetch(:tool_prefs)).to eq(choice: :none, calls: :one)
  end

  it "rejects an oversized RubyLLM batch without executing a partial batch" do
    executions = []
    tool = with_stubbed_class("SpecRealOversizedTool", Smith::Tool) do
      define_method(:perform) do |value:|
        executions << value
        value
      end
    end.new
    instrumentation = []
    responses = [
      build_response(tool_calls: {
                       "call-1" => build_tool_call(id: "call-1", name: :spec_real_oversized, arguments: { value: 1 }),
                       "call-2" => build_tool_call(id: "call-2", name: :spec_real_oversized, arguments: { value: 2 })
                     }),
      build_response(content: "bounded answer")
    ]
    chat = build_chat(responses: responses, instrumentation: instrumentation).with_tool(tool)

    result = with_allowance(1) { chat.complete }

    expect(result.content).to eq("bounded answer")
    expect(executions).to be_empty
    expect(chat.messages.select(&:tool_result?).map(&:tool_call_id)).to eq(%w[call-1 call-2])
    expect(chat.messages.select(&:tool_result?).map(&:content)).to all(
      include("tool_call_budget_exhausted")
    )
    expect(chat.provider_snapshots.last).to eq(
      tools: [], tool_prefs: { choice: :none, calls: nil }, concurrency: :threads
    )
  end

  it "bounds unavailable provider tool calls that never reach a Smith tool" do
    executions = []
    tool = with_stubbed_class("SpecRealAvailableTool", Smith::Tool) do
      define_method(:perform) do |value:|
        executions << value
        value
      end
    end.new
    instrumentation = []
    responses = [
      build_response(tool_calls: {
                       "call-missing" => build_tool_call(id: "call-missing", name: :missing_tool, arguments: {})
                     }),
      build_response(content: "answered without another tool call")
    ]
    chat = build_chat(responses: responses, instrumentation: instrumentation).with_tool(tool)
    remaining = nil

    result = with_allowance(1) do |allowance|
      response = chat.complete
      remaining = allowance.remaining
      response
    end

    expect(result.content).to eq("answered without another tool call")
    expect(executions).to be_empty
    expect(remaining).to eq(0)
    expect(chat.messages.select(&:tool_result?).map(&:tool_call_id)).to eq(["call-missing"])
    expect(chat.messages.select(&:tool_result?).sole.content).to include("unavailable tool")
    expect(chat.provider_snapshots.last.fetch(:tools)).to be_empty
  end

  it "fail-fast bounds unavailable provider calls across completion rounds" do
    tool = with_stubbed_class("SpecFailFastAvailableTool", Smith::Tool) do
      def perform(**) = raise("must not execute")
    end.new
    responses = 2.times.map do |index|
      id = "missing-#{index + 1}"
      build_response(tool_calls: {
                       id => build_tool_call(id:, name: :missing_tool, arguments: {})
                     })
    end
    chat = build_chat(responses:, instrumentation: []).with_tool(tool)
    allowance = nil

    expect do
      with_fail_fast_allowance(1) do |current_allowance|
        allowance = current_allowance
        chat.complete
      end
    end.to raise_error(Smith::BudgetExceeded, "agent tool_calls budget exceeded")
    expect(allowance.remaining).to eq(0)
    expect(chat.messages.select(&:tool_result?).map(&:tool_call_id)).to eq(["missing-1"])
  end

  it "bounds schema-invalid calls rejected by the host tool contract" do
    executions = []
    tool = with_stubbed_class("SpecRealValidatedTool", Smith::Tool) do
      define_method(:perform) do |**input|
        executions << input
        if input.key?(:required_value)
          input.fetch(:required_value)
        else
          { error: "missing required_value" }
        end
      end
    end.new
    instrumentation = []
    responses = [
      build_response(tool_calls: {
                       "call-invalid" => build_tool_call(id: "call-invalid", name: :spec_real_validated, arguments: {})
                     }),
      build_response(content: "reported invalid input")
    ]
    chat = build_chat(responses: responses, instrumentation: instrumentation).with_tool(tool)
    remaining = nil
    execution_started = nil

    result = with_allowance(1) do |allowance|
      response = chat.complete
      remaining = allowance.remaining
      execution_started = Smith::Tool.current_tool_execution_tracker.started?
      response
    end

    expect(result.content).to eq("reported invalid input")
    expect(executions).to eq([{}])
    expect(remaining).to eq(0)
    expect(execution_started).to be(true)
    expect(chat.messages.select(&:tool_result?).sole.content).to include("missing required_value")
  end

  it "requires a separate admitted primitive for nested Smith tool execution" do
    executions = []
    nested_tool = with_stubbed_class("SpecRealNestedTool", Smith::Tool) do
      define_method(:perform) do |value:|
        executions << [:nested, value]
        value
      end
    end.new
    outer_tool = with_stubbed_class("SpecRealOuterTool", Smith::Tool) do
      define_method(:perform) do |value:|
        executions << [:outer, value]
        nested_tool.execute(value: value)
      end
    end.new
    instrumentation = []
    responses = [
      build_response(tool_calls: {
                       "call-outer" => build_tool_call(id: "call-outer", name: :spec_real_outer,
                                                       arguments: { value: 7 })
                     }),
      build_response(content: "nested work complete")
    ]
    chat = build_chat(responses: responses, instrumentation: instrumentation).with_tool(outer_tool)
    remaining = nil

    expect do
      with_allowance(2) do |allowance|
        chat.complete
      ensure
        remaining = allowance.remaining
      end
    end.to raise_error(Smith::ToolExecutionNotAdmitted, /exact admitted dispatch authority/)

    expect(executions).to eq([[:outer, 7]])
    expect(remaining).to eq(1)
  end

  it "validates the perform signature before consuming or executing a Smith tool" do
    executions = []
    tool = with_stubbed_class("SpecRequiredArgumentTool", Smith::Tool) do
      define_method(:perform) do |required:|
        executions << required
        required
      end
    end.new
    chat = build_chat(
      responses: [
        build_response(tool_calls: {
                         "call-invalid" => build_tool_call(id: "call-invalid", name: :spec_required_argument,
                                                           arguments: {})
                       }),
        build_response(content: "invalid arguments reported")
      ],
      instrumentation: []
    ).with_tool(tool)
    remaining = nil

    result = with_allowance(1) do |allowance|
      response = chat.complete
      remaining = allowance.remaining
      response
    end

    expect(result.content).to eq("invalid arguments reported")
    expect(executions).to be_empty
    expect(remaining).to eq(0)
    expect(chat.messages.select(&:tool_result?).sole.content).to include(
      "Invalid tool arguments: missing keyword: required"
    )
  end

  it "notifies the host when RubyLLM rejects admitted tool arguments" do
    failures = []
    tool = with_stubbed_class("SpecDurableInvalidArgumentsTool", Smith::Tool) do
      def perform(required:) = required
    end.new
    chat = build_chat(
      responses: [
        build_response(tool_calls: {
                         "call-invalid" => build_tool_call(id: "call-invalid", name: :spec_durable_invalid_arguments,
                                                           arguments: {})
                       }),
        build_response(content: "invalid arguments reported")
      ],
      instrumentation: []
    ).with_tool(tool)

    result = with_allowance(1) do
      Smith::Tool.with_invocation_context(
        Object.new.freeze,
        batch_admitter: ->(requests:) { expect(requests.length).to eq(1) },
        failure_handler: ->(request:, error:) { failures << [request, error] }
      ) { chat.complete }
    end

    expect(result.content).to eq("invalid arguments reported")
    expect(failures.sole.first.invocation.tool_call_id).to eq("call-invalid")
    expect(failures.sole.last).to be_a(Smith::ToolDispatchRejected)
  end

  it "propagates a terminal receipt failure after RubyLLM rejects admitted arguments" do
    attempts = 0
    tool = with_stubbed_class("SpecDurableInvalidArgumentsReceiptFailureTool", Smith::Tool) do
      def perform(required:) = required
    end.new
    chat = build_chat(
      responses: [
        build_response(tool_calls: {
                         "call-invalid" => build_tool_call(
                           id: "call-invalid",
                           name: :spec_durable_invalid_arguments_receipt_failure,
                           arguments: {}
                         )
                       })
      ],
      instrumentation: []
    ).with_tool(tool)
    failure_handler = lambda do |request:, error:|
      request && error
      attempts += 1
      raise "receipt write failed"
    end

    matcher = raise_error(Smith::ToolFailureNotificationFailed) do |error|
      expect(error.dispatch_error).to be_a(Smith::ToolDispatchRejected)
      expect(error.notification_error.message).to eq("receipt write failed")
    end
    expect do
      with_allowance(1) do
        Smith::Tool.with_invocation_context(
          Object.new.freeze,
          batch_admitter: ->(requests:) { requests.sole },
          failure_handler:
        ) { chat.complete }
      end
    end.to matcher
    expect(attempts).to be >= 1
  end

  it "notifies the host when a RubyLLM callback rejects an admitted invocation" do
    failures = []
    executions = []
    tool = with_stubbed_class("SpecCallbackRejectedInvocationTool", Smith::Tool) do
      define_method(:perform) { |value:| executions << value }
    end.new
    chat = build_chat(
      responses: [
        build_response(tool_calls: {
                         "call-callback" => build_tool_call(id: "call-callback",
                                                            name: :spec_callback_rejected_invocation,
                                                            arguments: { value: "original" })
                       })
      ],
      instrumentation: []
    ).with_tool(tool)
    chat.before_tool_call { raise "callback rejected dispatch" }

    expect do
      with_allowance(1) do
        Smith::Tool.with_invocation_context(
          Object.new.freeze,
          batch_admitter: ->(requests:) { expect(requests.length).to eq(1) },
          failure_handler: ->(request:, error:) { failures << [request, error] }
        ) { chat.complete }
      end
    end.to raise_error(Smith::ToolDispatchRejected, "tool invocation failed before execution")
    expect(executions).to be_empty
    expect(failures.sole.first.invocation.tool_call_id).to eq("call-callback")
    expect(failures.sole.last).to be_a(Smith::ToolDispatchRejected)
  end

  it "rejects non-Smith tools before bounded provider execution" do
    plain_tool = Class.new(RubyLLM::Tool) do
      def name = "plain_tool"
      def execute(value:) = value
    end.new
    chat = build_chat(responses: [build_response(content: "unused")], instrumentation: []).with_tool(plain_tool)

    expect do
      with_allowance(1) { chat.complete }
    end.to raise_error(
      Smith::BoundedCompletionError,
      "tool_budget_exhaustion :complete requires Smith::Tool bindings; unsupported: plain_tool"
    )
    expect(chat.provider_snapshots).to be_empty
  end

  it "rejects raw provider params that could override bounded tool controls" do
    chat = build_chat(responses: [build_response(content: "unused")], instrumentation: [])
    chat.with_params(tools: [{ type: "function" }], tool_choice: :required)

    expect do
      with_allowance(0) { chat.complete }
    end.to raise_error(
      Smith::BoundedCompletionError,
      "bounded completion reserves provider tool params: tool_choice, tools"
    )
    expect(chat.provider_snapshots).to be_empty
  end

  it "rejects a provider batch that exceeds the effective workflow budget" do
    executions = []
    tool = with_stubbed_class("SpecWorkflowBoundedTool", Smith::Tool) do
      define_method(:perform) do |value:|
        executions << value
        value
      end
    end.new
    chat = build_chat(
      responses: [
        build_response(tool_calls: {
                         "call-1" => build_tool_call(id: "call-1", name: :spec_workflow_bounded,
                                                     arguments: { value: 1 }),
                         "call-2" => build_tool_call(id: "call-2", name: :spec_workflow_bounded,
                                                     arguments: { value: 2 })
                       }),
        build_response(content: "completed without partial execution")
      ],
      instrumentation: []
    ).with_tool(tool)
    ledger = Smith::Budget::Ledger.new(limits: { tool_calls: 1 })
    remaining = nil
    Smith::Tool.current_ledger = ledger

    result = with_allowance(2) do |allowance|
      response = chat.complete
      remaining = allowance.remaining
      response
    end

    expect(result.content).to eq("completed without partial execution")
    expect(executions).to be_empty
    expect(remaining).to eq(2)
    expect(ledger.consumed.fetch(:tool_calls, 0)).to eq(0)
  ensure
    Smith::Tool.current_ledger = nil
  end

  it "preserves RubyLLM's forced-choice reset after an admitted call" do
    tool = with_stubbed_class("SpecForcedChoiceTool", Smith::Tool) do
      define_method(:perform) { |value:| value }
    end.new
    chat = build_chat(
      responses: [
        build_response(tool_calls: {
                         "call-1" => build_tool_call(id: "call-1", name: :spec_forced_choice,
                                                     arguments: { value: 1 })
                       }),
        build_response(content: "done")
      ],
      instrumentation: []
    ).with_tool(tool, choice: :spec_forced_choice)

    result = with_allowance(1) { chat.complete }

    expect(result.content).to eq("done")
    expect(chat.tool_prefs).to eq(choice: nil, calls: nil)
  end

  it "iterates through long finite tool loops without recursive stack growth" do
    call_count = 600
    executions = 0
    tool = with_stubbed_class("SpecIterativeBoundedTool", Smith::Tool) do
      define_method(:perform) do |value:|
        executions += 1
        value
      end
    end.new
    calls = Array.new(call_count) do |index|
      id = "call-#{index}"
      build_response(tool_calls: {
                       id => build_tool_call(id:, name: :spec_iterative_bounded, arguments: { value: index })
                     })
    end
    chat = build_chat(
      responses: calls << build_response(content: "iterative completion"),
      instrumentation: []
    ).with_tool(tool)

    result = with_allowance(call_count) { chat.complete }

    expect(result.content).to eq("iterative completion")
    expect(executions).to eq(call_count)
  end

  it "iterates through long fail-fast tool loops without recursive stack growth" do
    call_count = 2_000
    executions = 0
    tool = with_stubbed_class("SpecIterativeFailFastTool", Smith::Tool) do
      define_method(:perform) do |value:|
        executions += 1
        value
      end
    end.new
    responses = Array.new(call_count) do |index|
      id = "fail-fast-#{index}"
      build_response(tool_calls: {
                       id => build_tool_call(id:, name: :spec_iterative_fail_fast, arguments: { value: index })
                     })
    end
    chat = build_chat(
      responses: responses << build_response(content: "iterative fail-fast completion"),
      instrumentation: []
    ).with_tool(tool)

    result = with_fail_fast_allowance(call_count) { chat.complete }

    expect(result.content).to eq("iterative fail-fast completion")
    expect(executions).to eq(call_count)
  end

  it "restores chat state and permits a later finalization attempt after provider failure" do
    instrumentation = []
    chat = build_chat(
      responses: [RuntimeError.new("provider unavailable"), build_response(content: "recovered answer")],
      instrumentation: instrumentation
    )

    result = with_allowance(0) do
      expect { chat.complete }.to raise_error(RuntimeError, "provider unavailable")
      expect(chat.tools).to be_empty
      expect(chat.tool_prefs).to eq(choice: nil, calls: nil)
      expect(chat.concurrency).to eq(:threads)

      chat.complete
    end

    expect(result.content).to eq("recovered answer")
    expect(chat.provider_snapshots).to all(
      eq(tools: [], tool_prefs: { choice: :none, calls: nil }, concurrency: :threads)
    )
  end

  it "runs a later ask as its own tool-disabled completion after graceful exhaustion" do
    executions = []
    tool = with_stubbed_class("SpecLaterAskBoundedTool", Smith::Tool) do
      define_method(:perform) do |value:|
        executions << value
        { value: value }
      end
    end.new
    chat = build_chat(
      responses: [
        build_response(tool_calls: {
                         "call-1" => build_tool_call(id: "call-1", name: :spec_later_ask_bounded,
                                                     arguments: { value: 1 })
                       }),
        build_response(content: "first answer"),
        build_response(content: "second answer")
      ],
      instrumentation: []
    ).with_tool(tool)

    with_allowance(1) do
      expect(chat.complete.content).to eq("first answer")
      expect(chat.complete.content).to eq("second answer")
    end

    expect(executions).to eq([1])
    expect(chat.provider_snapshots.last).to eq(
      tools: [], tool_prefs: { choice: :none, calls: nil }, concurrency: :threads
    )
    expect(chat.tools.keys).to eq([:spec_later_ask_bounded])
  end

  it "rejects concurrent completion on one bounded chat without corrupting the active call" do
    provider_started = Queue.new
    release_provider = Queue.new
    instrumentation = []
    chat = build_chat(
      responses: [
        proc do
          provider_started << true
          release_provider.pop
          build_response(content: "winner")
        end
      ],
      instrumentation: instrumentation
    )
    allowance = Smith::Tool::CallAllowance.new(1, on_exhaustion: :complete)
    tracker = Smith::Tool::ExecutionTracker.new
    context = Smith::Tool::ScopedContext.capture.merge(
      current_tool_call_allowance: allowance,
      current_tool_execution_tracker: tracker
    ).freeze
    winner = Thread.new do
      Smith::Tool::ScopedContext.around(context) { chat.complete }
    end
    provider_started.pop

    expect do
      Smith::Tool::ScopedContext.around(context) { chat.complete }
    end.to raise_error(Smith::Error, "concurrent or reentrant completion on one bounded Smith chat is unsupported")

    release_provider << true
    expect(winner.value.content).to eq("winner")
    expect(chat.tool_prefs).to eq(choice: nil, calls: nil)
    expect(chat.concurrency).to eq(:threads)
  ensure
    release_provider << true if winner&.alive?
    winner&.join
  end

  it "rejects callback reentry into the same bounded chat" do
    chat = build_chat(responses: [build_response(content: "outer")], instrumentation: [])
    chat.before_message { chat.complete }

    expect do
      with_allowance(0) { chat.complete }
    end.to raise_error(Smith::Error, "concurrent or reentrant completion on one bounded Smith chat is unsupported")
    expect(chat.provider_snapshots.length).to eq(1)
  end

  it "keeps the outer ownership after rejecting reentry" do
    guard = Smith::Tool::BoundedCompletionGuard.new
    entered = Queue.new
    release = Queue.new
    owner = Object.new
    outer = Thread.new do
      guard.around_completion(owner, reentrant: false) do
        entered << true
        release.pop
      end
    end
    entered.pop

    expect do
      guard.around_completion(owner, reentrant: false) { nil }
    end.to raise_error(Smith::Error, "concurrent or reentrant completion on one bounded Smith chat is unsupported")
    expect do
      guard.around_completion(Object.new, reentrant: false) { nil }
    end.to raise_error(Smith::Error, "concurrent or reentrant completion on one bounded Smith chat is unsupported")
  ensure
    release << true if outer&.alive?
    outer&.join
  end
end
