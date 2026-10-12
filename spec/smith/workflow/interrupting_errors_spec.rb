# frozen_string_literal: true

require "smith/testing/rspec"

# Smith.config.interrupting_errors: errors that interrupt a step instead of
# failing it, as when the host's database or queue is out of reach.
RSpec.describe "Smith::Interruptions" do
  include_context "with a recording budget ledger"

  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:testing) { Smith::Testing }
  let(:tries) { [] }

  around do |example|
    saved = Smith.config.interrupting_errors
    example.run
  ensure
    Smith.config.interrupting_errors = saved
  end

  before do
    stub_const("SpecOutage", Class.new(StandardError))
    stub_const("SpecOutageWrapper", Class.new(StandardError))
    Smith.config.interrupting_errors = [SpecOutage]
  end

  # A workflow whose :work step records each try's key and runs `body`, with
  # a retry and a failure route, then a :finish step.
  def working(name, mode: :lax, retry_policy: { attempts: 3 }, &body)
    recorded = tries
    with_stubbed_class(name, workflow_class) do
      idempotency_mode mode
      initial_state :idle
      state :failed
      transition :work, from: :idle, to: :worked do
        compute do |step|
          recorded << step.idempotency_key
          instance_exec(step, &body)
        end
        retry_on StandardError, **retry_policy
        on_failure :fail
      end
      transition(:finish, from: :worked, to: :done) { compute { |_step| nil } }
    end
  end

  describe "the setting" do
    it "lists error classes, none by default, and refuses what is not one or would match every error" do
      Smith.config.interrupting_errors = nil
      expect(Smith.config.interrupting_errors).to eq([])

      Smith.config.interrupting_errors = [SpecOutage, IOError, SpecOutage]
      expect(Smith.config.interrupting_errors).to eq([SpecOutage, IOError])
      expect(Smith.config.interrupting_errors).to be_frozen

      [["SpecOutage"], [Object], [Exception], [StandardError], [Interrupt], [NoMemoryError],
       [SpecOutage, StandardError]].each do |value|
        expect { Smith.config.interrupting_errors = value }.to raise_error(ArgumentError, /interrupting_errors/)
      end
    end
  end

  describe "a step that meets one" do
    it "stops where it is: no failure route, no retry, no failure recorded or emitted, and the caller gets it" do
      raised = SpecOutage.new("database out of reach")
      run = working("SpecInterruptedWorkflow") { |_step| raise raised }.new(context: {})
      failures = []
      subscription = Smith::Events.on(Smith::Events::StepFailed) { |event| failures << event }

      expect { run.advance! }.to(raise_error { |error| expect(error).to equal(raised) })
      expect([run.state, tries.length, run.to_state[:last_failed_step], failures]).to eq([:idle, 1, nil, []])
    ensure
      subscription&.cancel
    end

    it "is traced as interrupted, not failed, by a deterministic step" do
      traces = Smith::Trace::Memory.new
      allow(Smith::Trace).to receive(:resolve_adapter).and_return(traces)
      run = working("SpecTracedInterruptedWorkflow") { |_step| raise SpecOutage, "down" }.new(context: {})

      expect { run.advance! }.to raise_error(SpecOutage)
      steps = traces.traces.select { _1[:type] == :deterministic_step }
      outcomes = steps.map { _1[:data].slice(:outcome, :error_class) }
      expect(outcomes).to eq([{ outcome: :started }, { outcome: :interrupted }])
    end

    it "takes its route as any error does when the host names no interrupting errors" do
      Smith.config.interrupting_errors = []
      result = working("SpecRoutedWorkflow") { |_step| raise SpecOutage, "down" }.new(context: {}).run!

      expect([result.state, result.last_error.class, tries.length]).to eq([:failed, SpecOutage, 3])
    end

    it "passes on the interrupting error an error was raised from, however it was wrapped" do
      klass = working("SpecWrappedWorkflow") do |_step|
        raise SpecOutage, "down"
      rescue SpecOutage
        raise SpecOutageWrapper, "could not save"
      end

      expect { klass.new(context: {}).advance! }.to raise_error(SpecOutage, "down")
      expect(tries.length).to eq(1)
    end

    it "never enters a durable retry's wait" do
      durable = { attempts: 3, backoff: 30, durable: true }
      klass = working("SpecDurableInterruptedWorkflow", retry_policy: durable) { |_step| raise SpecOutage, "down" }
      klass.new(context: {}).persist!("run-durable", adapter:)

      expect { klass.restore("run-durable", adapter:).advance_persisted!("run-durable", adapter:) }
        .to raise_error(SpecOutage)
      expect(klass.restore("run-durable", adapter:).waiting?).to be(false)
    end
  end

  describe "a persisted run" do
    it "keeps a lax run as the step left it, and takes the step again under the same keys when next advanced" do
      outages = [SpecOutage.new("down")]
      klass = working("SpecReplayedWorkflow") do |_step|
        outage = outages.shift
        raise outage if outage
      end
      klass.new(context: {}).persist!("run-lax", adapter:)

      expect { klass.restore("run-lax", adapter:).advance_persisted!("run-lax", adapter:) }.to raise_error(SpecOutage)

      klass.restore("run-lax", adapter:).run_persisted!("run-lax", adapter:)

      expect([klass.restore("run-lax", adapter:).state, tries.length, tries.uniq.length]).to eq([:done, 2, 1])
    end

    it "leaves a strict run's step under way, as a worker that stopped leaves it" do
      klass = working("SpecStrictInterruptedWorkflow", mode: :strict) { |_step| raise SpecOutage, "down" }
      klass.new(context: {}).persist!("run-strict", adapter:)

      expect { klass.restore("run-strict", adapter:).advance_persisted!("run-strict", adapter:) }
        .to raise_error(SpecOutage)
      expect { klass.restore("run-strict", adapter:) }.to raise_error(Smith::StepInProgressOnRestore)
    end
  end

  describe "an agent step" do
    it "stops when a tool meets one, instead of failing as an uncertain tool outcome" do
      stub_const("SpecOutageTool", Class.new(Smith::Tool) do
        param :query, type: :string, required: true
        define_method(:perform) { |query:| raise SpecOutage, "down at #{query}" }
      end)
      agent("SpecOutageToolAgent") { tools SpecOutageTool }
      testing.stub_agent(SpecOutageToolAgent, outputs: [testing.tool_call(SpecOutageTool, query: "lookup"), "Done."])
      klass = asking("SpecOutageToolWorkflow")
      run = klass.new(context: {})

      expect { run.run! }.to raise_error(SpecOutage, "down at lookup")
      expect(run.state).to eq(:idle)

      Smith.config.interrupting_errors = []
      testing.stub_agent(SpecOutageToolAgent, outputs: [testing.tool_call(SpecOutageTool, query: "lookup"), "Done."])
      routed = klass.new(context: {}).run!
      expect([routed.state, routed.last_error.class]).to eq([:failed, Smith::ToolOutcomeUncertain])
    end

    it "stops when its budget ledger meets one, instead of failing as a ledger error" do
      agent("SpecOutageHeldAgent")
      testing.stub_agent(SpecOutageHeldAgent, outputs: "Held.")
      down = ledger_class.new(admit: ->(_amount) { raise SpecOutage, "ledger down" })
      klass = asking("SpecOutageHeldWorkflow") { |_context| down }

      expect { klass.new(context: {}).run! }.to raise_error(SpecOutage, "ledger down")

      Smith.config.interrupting_errors = []
      routed = klass.new(context: {}).run!
      expect([routed.state, routed.last_error.class]).to eq([:failed, Smith::BudgetLedgerError])
    end
  end

  describe "a batch step's completion" do
    it "raises one met while the delivery completes the step, and the run keeps waiting for it" do
      stub_const("SpecOutageGuards", Class.new(Smith::Guardrails) do
        class << self
          attr_accessor :down
        end
        output :check
        define_method(:check) { |_payload| raise SpecOutage, "down" if self.class.down }
      end)
      Smith.config.batch_queue = batch_queue
      agent("SpecOutageBatchAgent")
      testing.stub_agent(SpecOutageBatchAgent, outputs: "stubbed")
      klass = with_stubbed_class("SpecOutageBatchWorkflow", workflow_class) do
        guardrails SpecOutageGuards
        initial_state :idle
        state :failed
        seed_messages { |_context| [{ role: :user, content: "classify this posting" }] }
        transition :ask, from: :idle, to: :done do
          execute :spec_ledger_agent, output_to: :answer, mode: :batch
          on_failure :fail
        end
      end
      run = klass.new(context: {})
      testing.run_until_waiting(run)
      payload = testing.batch_payload(run, testing.batch_result("From the batch."))
      SpecOutageGuards.down = true

      expect { testing.resume_with(run, payload:) }.to raise_error(SpecOutage, "down")
      expect(run).to be_waiting_for(kind: :batch)

      SpecOutageGuards.down = false
      expect(testing.resume_with(run, payload:)).to eq(:resumed)
      expect(run.state).to eq(:done)
    end
  end

  describe "work split across branches and runs" do
    it "surfaces one met in a parallel branch from the step" do
      stub_const("SpecOutageParallelAgent", Class.new(Smith::Agent) do
        register_as :spec_outage_parallel_agent
        model "gpt-5-mini"
      end)
      SpecOutageParallelAgent.define_singleton_method(:chat) do |**|
        Object.new.tap do |chat|
          chat.define_singleton_method(:add_message) { |_message| nil }
          chat.define_singleton_method(:with_schema) { |_schema| self }
          chat.define_singleton_method(:complete) { raise SpecOutage, "down" }
        end
      end
      klass = with_stubbed_class("SpecOutageParallelWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :ask, from: :idle, to: :done do
          execute :spec_outage_parallel_agent, parallel: true, count: 3
          on_failure :fail
        end
      end
      run = klass.new(context: {})

      expect { run.run! }.to raise_error(SpecOutage, "down")
      expect(run.state).to eq(:idle)
    ensure
      Smith::Agent::Registry.delete(:spec_outage_parallel_agent)
    end

    it "prefers an interruption to any other branch error but a process-fatal one" do
      ordinary = RuntimeError.new("ordinary")
      wrapped = begin
        begin
          raise SpecOutage, "down"
        rescue SpecOutage
          raise SpecOutageWrapper, "wrapped"
        end
      rescue SpecOutageWrapper => e
        e
      end
      fatal = NoMemoryError.new("fatal")
      parallel = Smith::Workflow::Parallel

      expect(parallel.preferred_error([ordinary, wrapped])).to equal(wrapped)
      expect(parallel.preferred_error([Smith::ToolFailureNotificationFailed.new(dispatch_error: ordinary,
                                                                                notification_error: ordinary),
                                       wrapped])).to equal(wrapped)
      expect(parallel.preferred_error([wrapped, fatal])).to equal(fatal)
    end

    it "stops the parent's step when an inline child run meets one, instead of handing back a failed child" do
      Smith.config.run_launcher = Smith::Launchers::Inline.new
      working("SpecOutageChildWorkflow") { |_step| raise SpecOutage, "down" }
      parent = with_stubbed_class("SpecOutageParentWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :split, from: :idle, to: :done do
          map :items, workflow: SpecOutageChildWorkflow, max_items: 2, timeout: 60,
                      input: ->(item, _context) { { item: } }, into: :results, collect: :states
          on_failure :fail
        end
      end
      run = parent.new(context: { items: [1] })

      expect { run.run! }.to raise_error(SpecOutage, "down")
      expect(run.state).to eq(:idle)
    end

    it "notifies no tool failure handler: the host reconciles what the batch left unsettled" do
      failures = []
      tool = with_stubbed_class("SpecOutageBatchTool", Smith::Tool) do
        define_method(:perform) { |**| raise SpecOutage, "down" }
      end.new
      chat = Smith::Tool::ChatExecutionContext.install(SpecToolExecutionChat.new(probe: tool))
      call = RubyLLM::ToolCall.new(id: "outage", name: :probe, arguments: {})
      run_batch = lambda do
        Smith::Tool.with_invocation_context(
          Object.new.freeze,
          batch_admitter: ->(requests:) { requests },
          failure_handler: ->(request:, error:) { failures << [request, error] }
        ) { chat.run_sequential_batch(only: call) }
      end

      expect { run_batch.call }.to raise_error(SpecOutage, "down")
      expect(failures).to be_empty

      Smith.config.interrupting_errors = []
      expect { run_batch.call }.to raise_error(SpecOutage, "down")
      expect(failures.map { _2.class }).to eq([SpecOutage])
    end
  end

  describe "tools run together" do
    it "raises a sibling's interruption over another sibling's tool capture failure" do
      capture_started = Queue.new
      capture_tool = with_stubbed_class("SpecOutageSiblingCaptureTool", Smith::Tool) do
        capture_result(strict: true) { |_kwargs, result| result }
        def perform(**_kwargs) = :captured
      end.new
      outage_tool = with_stubbed_class("SpecOutageSiblingTool", Smith::Tool) do
        define_method(:perform) do |**_kwargs|
          raise "capture barrier timed out" unless capture_started.pop(timeout: 5)

          raise SpecOutage, "down"
        end
      end.new
      Smith::Tool.current_tool_result_collector = lambda do |_entry|
        capture_started << true
        raise "collector unavailable"
      end
      chat = Smith::Tool::ChatExecutionContext.install(
        SpecToolExecutionChat.new(capture: capture_tool, outage: outage_tool)
      )
      call = Data.define(:name, :arguments)
      calls = { first: call.new(name: :outage, arguments: {}), second: call.new(name: :capture, arguments: {}) }

      expect { chat.run_concurrently(calls) }.to raise_error(SpecOutage, "down")
    ensure
      Smith::Tool.current_tool_result_collector = nil
    end

    it "raises one met in a tool callback as it is, never as a dispatch the host is told was rejected" do
      failures = []
      tool = with_stubbed_class("SpecOutageCallbackTool", Smith::Tool) { def perform(**) = :unused }.new
      callback_chat_class = Class.new(SpecToolExecutionChat) do
        def before_tool_call(&block) = @before_tool_call = block

        private

        def execute_tool_with_callbacks(tool_call)
          @before_tool_call&.call(tool_call)
          execute_tool(tool_call)
        end

        def handle_sequential_tool_calls(tool_calls) = tool_calls.each_value.map { execute_tool_with_callbacks(_1) }
      end
      chat = Smith::Tool::ChatExecutionContext.install(callback_chat_class.new(probe: tool))
      chat.before_tool_call { |_call| raise SpecOutage, "down" }
      call = RubyLLM::ToolCall.new(id: "outage", name: :probe, arguments: {})
      run_batch = lambda do
        Smith::Tool.with_invocation_context(
          Object.new.freeze,
          batch_admitter: ->(requests:) { requests },
          failure_handler: ->(request:, error:) { request && (failures << error) }
        ) { chat.run_sequential_batch(only: call) }
      end

      expect { run_batch.call }.to raise_error(SpecOutage, "down")
      expect(failures).to be_empty

      Smith.config.interrupting_errors = []
      expect { run_batch.call }.to raise_error(Smith::ToolDispatchRejected)
      expect(failures.map(&:class)).to eq([Smith::ToolDispatchRejected])
    end
  end

  describe "a tool failure handler" do
    it "that meets one stops the batch with it, leaving what it had not settled unsettled" do
      notified = []
      tool = with_stubbed_class("SpecOutageHandlerTool", Smith::Tool) do
        define_method(:perform) { |**| raise "service answered 500" }
      end.new
      chat = Smith::Tool::ChatExecutionContext.install(SpecToolExecutionChat.new(probe: tool))
      call = RubyLLM::ToolCall.new(id: "handled", name: :probe, arguments: {})

      expect do
        Smith::Tool.with_invocation_context(
          Object.new.freeze,
          batch_admitter: ->(requests:) { requests },
          failure_handler: ->(request:, error:) { request && (notified << error) && raise(SpecOutage, "receipts down") }
        ) { chat.run_sequential_batch(only: call) }
      end.to raise_error(SpecOutage, "receipts down")
      expect(notified.map(&:class)).to eq([RuntimeError])
    end

    it "that meets one for a call of tools run together wins over a sibling's error that came first" do
      sibling_settled = Queue.new
      waiting_tool = with_stubbed_class("SpecOutageLateTool", Smith::Tool) do
        define_method(:perform) do |**|
          raise "sibling barrier timed out" unless sibling_settled.pop(timeout: 5)

          raise "late failure"
        end
      end.new
      early_tool = with_stubbed_class("SpecOutageEarlyTool", Smith::Tool) do
        define_method(:perform) { |**| raise "early failure" }
      end.new
      callback_chat_class = Class.new(SpecToolExecutionChat) do
        private

        def execute_tool_with_callbacks(tool_call) = execute_tool(tool_call)

        def execute_tools_concurrently(tool_calls, &on_result)
          RubyLLM::ToolConcurrency.run(:threads, tool_calls, on_result:) { execute_tool_with_callbacks(_1) }
        end
      end
      chat = Smith::Tool::ChatExecutionContext.install(callback_chat_class.new(late: waiting_tool, early: early_tool))
      calls = {
        late: RubyLLM::ToolCall.new(id: "late", name: :late, arguments: {}),
        early: RubyLLM::ToolCall.new(id: "early", name: :early, arguments: {})
      }
      handler = lambda do |request:, error:|
        raise SpecOutage, "receipts down" if request.invocation.tool_call_id == "late"

        sibling_settled << error
      end

      expect do
        Smith::Tool.with_invocation_context(Object.new.freeze, batch_admitter: ->(requests:) { requests },
                                                               failure_handler: handler) do
          chat.run_concurrently(calls)
        end
      end.to raise_error(SpecOutage, "receipts down")
    end

    it "is never told an interrupted tool failed with a sibling's error that came first" do
      notified = []
      sibling_failed = Queue.new
      early_tool = with_stubbed_class("SpecOrdinarySiblingTool", Smith::Tool) do
        define_method(:perform) do |**|
          sibling_failed << true
          raise "ordinary failure"
        end
      end.new
      outage_tool = with_stubbed_class("SpecInterruptedSiblingTool", Smith::Tool) do
        define_method(:perform) do |**|
          raise "sibling barrier timed out" unless sibling_failed.pop(timeout: 5)

          sleep 0.1
          raise SpecOutage, "down"
        end
      end.new
      chat = Smith::Tool::ChatExecutionContext.install(
        SpecToolExecutionChat.new(early: early_tool, outage: outage_tool)
      )
      calls = {
        early: RubyLLM::ToolCall.new(id: "early", name: :early, arguments: {}),
        outage: RubyLLM::ToolCall.new(id: "outage", name: :outage, arguments: {})
      }

      expect do
        Smith::Tool.with_invocation_context(
          Object.new.freeze,
          batch_admitter: ->(requests:) { requests },
          failure_handler: ->(request:, error:) { notified << [request.invocation.tool_call_id, error.class] }
        ) { chat.run_concurrently(calls) }
      end.to raise_error(SpecOutage, "down")
      expect(notified.map(&:first)).not_to include("outage")
    end
  end

  describe "a durable composite branch" do
    it "raises one its agent meets, instead of keeping it as the branch's failed outcome" do
      composite_agent = Class.new(Smith::Agent)
      composite_agent.model("gpt-5-mini")
      composite_agent.define_singleton_method(:chat) do |**|
        Object.new.tap do |chat|
          chat.define_singleton_method(:add_message) { |_message| nil }
          chat.define_singleton_method(:with_schema) { |_schema| self }
          chat.define_singleton_method(:complete) { raise SpecOutage, "down" }
        end
      end
      composite_agent.execution_identity(Digest::SHA256.hexdigest("spec-outage-composite-agent"))
      Smith::Agent::Registry.register(:spec_outage_composite_agent, composite_agent)
      klass = stub_const("SpecOutageCompositeWorkflow", Class.new(Smith::Workflow) do
        definition_digest Digest::SHA256.hexdigest("spec-outage-composite")
        idempotency_mode :strict
        initial_state :idle
        state :done
        transition(:finish, from: :idle, to: :done) { execute :spec_outage_composite_agent, parallel: true, count: 2 }
      end)
      workflow = klass.new
      workflow.prepare_persisted_step!("run-composite", adapter:)
      dispatch = workflow.claim_prepared_step_dispatch!
      preparation = workflow.prepare_composite_step!
      branch = preparation.plan.branches.first
      execute = lambda do
        klass.recover_prepared_step(Smith::Workflow::PreparedStepRecovery.not_started(dispatch), adapter:)
             .execute_prepared_composite_branch!(execution: preparation.plan.execution_for(branch),
                                                 input: preparation.input)
      end

      expect { execute.call }.to raise_error(SpecOutage, "down")

      Smith.config.interrupting_errors = []
      expect(execute.call).to be_failed
    ensure
      Smith::Agent::Registry.delete(:spec_outage_composite_agent)
    end
  end

  describe "Smith::Interruptions.find" do
    it "follows a bounded chain of causes, so one that loops ends too" do
      looping = SpecOutageWrapper.new("loops")
      allow(looping).to receive(:cause).and_return(looping)
      wrapped = lambda do |wrappers|
        (1..wrappers).reduce(SpecOutage.new("down")) do |cause, n|
          SpecOutageWrapper.new("wrapper #{n}").tap { |wrapper| allow(wrapper).to receive(:cause).and_return(cause) }
        end
      end
      depth = Smith::Interruptions::CAUSE_DEPTH

      expect(Smith::Interruptions.find(looping)).to be_nil
      expect(Smith::Interruptions.find(wrapped.call(depth))).to be_nil
      expect(Smith::Interruptions.find(wrapped.call(depth - 1))&.message).to eq("down")
    end

    it "never looks through a provider's own failure: only its own class, named, interrupts" do
      raised_from = lambda do |inner, outer_class|
        raise inner
      rescue StandardError
        begin
          raise outer_class, "outer"
        rescue StandardError => e
          e
        end
      end
      refused = Errno::ECONNREFUSED.new
      transport = raised_from.call(refused, Faraday::ConnectionFailed)
      agent_error = begin
        raise transport
      rescue Faraday::ConnectionFailed
        begin
          raise Smith::AgentError, "provider out of reach"
        rescue Smith::AgentError => e
          e
        end
      end
      Smith.config.interrupting_errors = [Errno::ECONNREFUSED]

      expect([Smith::Interruptions.find(transport), Smith::Interruptions.find(agent_error)]).to eq([nil, nil])
      expect(Smith::Interruptions.find(raised_from.call(refused, SpecOutageWrapper))).to equal(refused)

      Smith.config.interrupting_errors = [Faraday::ConnectionFailed]
      expect(Smith::Interruptions.find(agent_error)).to equal(transport)
    end
  end
end
