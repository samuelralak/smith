# frozen_string_literal: true

require "json"

RSpec.describe "Smith::Workflow waits: await, delay, resume! and expire_wait!" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:sent) { [] }

  # Stands in for a process dying mid-step: not a StandardError.
  let(:crash) { Class.new(Exception) } # rubocop:disable Lint/InheritException

  def review_workflow(name, sent, mode: :lax, timeout: 3_600, **options)
    body = fetch_source_body(sent, timeout, options)
    with_stubbed_class(name, workflow_class) do
      idempotency_mode mode
      initial_state :requested
      state :failed
      max_transitions options.fetch(:max_transitions, 100)

      transition(:fetch_source, from: :requested, to: :fetched, &body)
      transition :source_unavailable, from: :requested, to: :unavailable
      transition(:finish, from: :fetched, to: :done) { compute { |_step| nil } }
    end
  end

  def fetch_source_body(sent, timeout, options)
    proc do
      await :source_ready, into: :source, timeout: do |step|
        sent << step.await_token
        step.resolve!({ "inline" => true }) if step.read_context(:source_ref) == "inline"
      end
      on_timeout :source_unavailable unless options[:no_timeout_route]
      on_failure :fail if options[:on_failure]
    end
  end

  def run_until_waiting(klass, key = "review-1", context: { source_ref: "doc-1" })
    workflow = klass.new(context:)
    workflow.run_persisted!(key, adapter:)
    workflow
  end

  describe "the DSL" do
    def declare(&body)
      Class.new(workflow_class) do
        initial_state :idle
        transition(:wait, from: :idle, to: :done, &body)
      end
    end

    it "requires a Symbol into: and a positive timeout, or a callable" do
      expect { declare { await :ev, into: "x", timeout: 1 } }.to raise_error(Smith::WorkflowError, /into:/)
      [0, -1, Float::INFINITY, "10", nil].each do |bad|
        expect { declare { await :ev, into: :x, timeout: bad } }.to raise_error(Smith::WorkflowError, /timeout/)
        expect { declare { delay bad } }.to raise_error(Smith::WorkflowError, /delay/)
      end
      callable = declare do
        await :ev, into: :x, timeout: ->(_context) { 5 }
        on_failure :fail
      end
      expect(callable).to be_a(Class)
    end

    it "requires an await to say where its timeout goes" do
      expect { declare { await :ev, into: :x, timeout: 5 } }
        .to raise_error(Smith::WorkflowError, /must declare on_timeout or on_failure/)
      expect(declare { delay 5 }).to be_a(Class)
    end

    it "takes on_timeout only on an await, and one execution body per transition" do
      expect { declare { on_timeout :late } }.to raise_error(Smith::WorkflowError, /on_timeout requires an await/)
      expect do
        declare do
          delay 5
          on_timeout :late
        end
      end.to raise_error(Smith::WorkflowError, /on_timeout/)
      expect do
        declare do
          await :ev, into: :x, timeout: 1
          compute { |_step| nil }
        end
      end.to raise_error(Smith::WorkflowError, /cannot declare both/)
    end
  end

  describe "entering a wait" do
    it "stops the run without counting a step, and describes the wait" do
      klass = review_workflow("SpecWaitEnterWorkflow", sent)
      before = Time.now.utc
      workflow = run_until_waiting(klass)

      wait = workflow.awaiting
      expect(workflow).to be_waiting
      expect(workflow.state).to eq(:requested)
      expect(workflow.to_state[:step_count]).to eq(0)
      expect(workflow.advance!).to be_nil
      expect(sent.size).to eq(1)
      expect(wait.to_h).to include(kind: :await, event: :source_ready, transition: :fetch_source, into: :source,
                                   token: sent.sole)
      expect(workflow.pending_transition_name).to eq(:fetch_source)
      expect(workflow).not_to be_terminal
      expect(wait.token).to match(/\A[0-9a-f]{64}\z/)
      expect(wait.deadline_at - wait.entered_at).to be_within(0.001).of(3_600)
      expect(wait.entered_at).to be >= before
      expect(JSON.parse(adapter.fetch("review-1"))["awaiting"]).to include("token" => wait.token)
    end

    it "runs the block again under the same token when the run is restored after a crash in it" do
      crash = self.crash
      sent = self.sent
      raised = [false]
      klass = with_stubbed_class("SpecWaitReplayWorkflow", workflow_class) do
        initial_state :requested

        transition(:start, from: :requested, to: :asking) { compute { |_step| nil } }
        transition :ask, from: :asking, to: :answered do
          await :answer, into: :answer, timeout: 60 do |step|
            sent << step.await_token
            unless raised[0]
              raised[0] = true
              raise crash
            end
          end
          on_timeout :give_up
        end
        transition :give_up, from: :asking, to: :abandoned
      end
      workflow = klass.new
      workflow.advance_persisted!("replay-1", adapter:)
      expect { workflow.advance_persisted!("replay-1", adapter:) }.to raise_error(crash)

      restored = klass.restore("replay-1", adapter:)
      restored.advance_persisted!("replay-1", adapter:)

      expect(sent.size).to eq(2)
      expect(sent.last).to eq(sent.first)
      expect(restored.awaiting.token).to eq(sent.first)
    end

    it "stores the wait advance_persisted! entered, and traces entry, resumption and timeout" do
      adapter_trace = Smith::Trace::Memory.new
      original = Smith.config.trace_adapter
      Smith.configure { |config| config.trace_adapter = adapter_trace }
      Smith::Trace.reset!
      klass = review_workflow("SpecWaitAdvanceWorkflow", sent)
      workflow = klass.new(context: { source_ref: "doc" })

      expect(workflow.advance_persisted!("advance-1", adapter:)).to be_nil
      stored = JSON.parse(adapter.fetch("advance-1"))
      expect(stored["awaiting"]).to include("token" => workflow.awaiting.token, "event" => "source_ready")
      klass.expire_wait!("advance-1", token: workflow.awaiting.token, now: workflow.awaiting.deadline_at, adapter:)

      outcomes = adapter_trace.traces.select { _1[:type] == :transition }.map { _1[:data][:outcome] }
      expect(outcomes).to include(:waiting, :timed_out)
    ensure
      Smith.configure { |config| config.trace_adapter = original }
      Smith::Trace.reset!
    end

    it "derives the token from the step's position and the event, as its idempotency keys are" do
      namespace = "00000000-0000-4000-8000-000000000000"
      klass = review_workflow("SpecWaitTokenWorkflow", sent)
      payload = JSON.parse(JSON.generate(klass.new(context: { source_ref: "doc" }).to_state))
      workflow = klass.from_state(payload.merge("execution_namespace" => namespace))

      workflow.run!

      position = Smith::IdempotencyKey.__send__(:root_scope, namespace).within(:step, 1, "fetch_source")
      expect(workflow.awaiting.token).to eq(position.within(:wait).key(%w[await source_ready]))
      expect(workflow.awaiting.token).not_to eq(position.key(%w[await source_ready]))
    end

    it "finishes at once when the block resolves the wait" do
      workflow = review_workflow("SpecWaitInlineWorkflow", sent).new(context: { source_ref: "inline" })

      result = workflow.run!

      expect(result.state).to eq(:done)
      expect(workflow).not_to be_waiting
      expect(workflow.to_state[:context][:source]).to eq(inline: true)
    end

    it "does not count a wait toward max_transitions" do
      klass = review_workflow("SpecWaitBudgetWorkflow", sent, max_transitions: 2)
      workflow = run_until_waiting(klass)

      expect(klass.resume!("review-1", event: :source_ready, token: workflow.awaiting.token, payload: {}, adapter:))
        .to eq(:resumed)
      expect(klass.restore("review-1", adapter:).run!.state).to eq(:done)
    end

    it "computes a callable timeout from the context and refuses one that is not positive" do
      klass = with_stubbed_class("SpecWaitCallableWorkflow", workflow_class) do
        initial_state :idle
        transition :wait, from: :idle, to: :done do
          await :ev, into: :reply, timeout: ->(context) { context[:seconds] }
          on_timeout :late
        end
        transition :late, from: :idle, to: :late
      end

      wait = klass.new(context: { seconds: 90 }).tap(&:run!).awaiting
      expect(wait.deadline_at - wait.entered_at).to be_within(0.001).of(90)
      expect { klass.new(context: { seconds: 0 }).run! }.to raise_error(Smith::WorkflowError, /timeout/)
    end
  end

  describe "resume!" do
    it "delivers the payload to into:, completes the step, and continues the run" do
      completed = []
      subscription = Smith::Events.on(Smith::Events::StepCompleted) { |event| completed << event.transition }
      klass = review_workflow("SpecWaitResumeWorkflow", sent)
      token = run_until_waiting(klass).awaiting.token

      result = klass.resume!("review-1", event: "source_ready", token:, payload: { "body" => "text", n: [1] }, adapter:)
      resumed = klass.restore("review-1", adapter:)

      expect(result).to eq(:resumed)
      expect(resumed.state).to eq(:fetched)
      expect(resumed).not_to be_waiting
      expect(resumed.to_state[:context][:source]).to eq(body: "text", n: [1])
      expect(resumed.to_state[:step_count]).to eq(1)
      expect(resumed.session_messages).to be_empty
      expect(completed).to eq([:fetch_source])
      expect(resumed.run_persisted!("review-1", adapter:).state).to eq(:done)
    ensure
      subscription&.cancel
    end

    it "is a no-op for another event or token, a delay, or a run that is not waiting" do
      klass = review_workflow("SpecWaitStaleWorkflow", sent)
      token = run_until_waiting(klass).awaiting.token
      stored = adapter.fetch("review-1")

      expect(klass.resume!("review-1", event: :other, token:, payload: {}, adapter:)).to eq(:stale)
      expect(klass.resume!("review-1", event: :source_ready, token: "0" * 64, payload: {}, adapter:)).to eq(:stale)
      expect(klass.resume!("missing", event: :source_ready, token:, payload: {}, adapter:)).to eq(:missing)
      expect(adapter.fetch("review-1")).to eq(stored)
      expect(klass.new.resume!(event: :source_ready, token:, payload: {})).to eq(:stale)
    end

    it "refuses a payload that is not JSON-shaped and keeps the run waiting" do
      workflow = run_until_waiting(review_workflow("SpecWaitBadPayloadWorkflow", sent))

      expect { workflow.resume!(event: :source_ready, token: workflow.awaiting.token, payload: { at: Object.new }) }
        .to raise_error(Smith::WorkflowError, /wait payload/)
      expect(workflow).to be_waiting
    end

    it "keeps into: within an explicit persist list, checked before the block sends anything" do
      context = Class.new(Smith::Context) { persist :other }
      klass = with_stubbed_class("SpecWaitPersistListWorkflow", workflow_class) do
        context_manager context
        initial_state :idle
        transition :wait, from: :idle, to: :done do
          await :ev, into: :reply, timeout: 60
          on_timeout :late
        end
        transition :late, from: :idle, to: :late
      end
      workflow = klass.new

      expect { workflow.run! }.to raise_error(Smith::UndeclaredContextKey)
      expect(workflow).not_to be_waiting
    end

    it "stores the resumed run with the version check" do
      klass = review_workflow("SpecWaitVersionWorkflow", sent)
      token = run_until_waiting(klass).awaiting.token
      racer = klass.restore("review-1", adapter:)

      klass.resume!("review-1", event: :source_ready, token:, payload: {}, adapter:)

      expect(racer.resume!(event: :source_ready, token:, payload: {})).to eq(:resumed)
      expect { racer.persist!("review-1", adapter:) }.to raise_error(Smith::PersistenceVersionConflict)
    end
  end

  describe "expire_wait!" do
    it "is not due before the deadline and stale for another token" do
      klass = review_workflow("SpecWaitNotDueWorkflow", sent)
      wait = run_until_waiting(klass).awaiting

      expect(klass.expire_wait!("review-1", token: wait.token, now: wait.deadline_at - 1, adapter:)).to eq(:not_due)
      expect(klass.expire_wait!("review-1", token: "f" * 64, now: wait.deadline_at + 1, adapter:)).to eq(:stale)
      expect(klass.restore("review-1", adapter:)).to be_waiting
    end

    it "takes on_timeout past the deadline" do
      klass = review_workflow("SpecWaitTimeoutWorkflow", sent)
      wait = run_until_waiting(klass).awaiting

      expect(klass.expire_wait!("review-1", token: wait.token, now: wait.deadline_at, adapter:)).to eq(:expired)
      expired = klass.restore("review-1", adapter:)

      expect(expired).not_to be_waiting
      expect(expired.to_state[:step_count]).to eq(1)
      expect(expired.run!.state).to eq(:unavailable)
    end

    it "takes on_failure with WaitTimedOut when no on_timeout is declared" do
      klass = review_workflow("SpecWaitFailureWorkflow", sent, no_timeout_route: true, on_failure: true)
      workflow = run_until_waiting(klass)
      wait = workflow.awaiting

      expect(workflow.expire_wait!(token: wait.token, now: wait.deadline_at + 1)).to eq(:expired)

      result = workflow.run!
      expect(result.state).to eq(:failed)
      expect(workflow.to_state[:last_failed_step]).to include(error_class: "Smith::WaitTimedOut")
      error = Smith::WaitTimedOut.new(transition: :t, event: "e", deadline_at: "x")
      expect(Smith::Errors.retryable?(error)).to be(false)
    end

    it "refuses an on_timeout route that does not start from the await's state" do
      klass = with_stubbed_class("SpecWaitOriginWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :wait, from: :idle, to: :done do
          await :ev, into: :reply, timeout: 60
          on_timeout :elsewhere
          on_failure :fail
        end
        transition :elsewhere, from: :other, to: :late
      end
      workflow = klass.new.tap(&:run!)
      wait = workflow.awaiting

      workflow.expire_wait!(token: wait.token, now: wait.deadline_at)

      expect(workflow.run!.state).to eq(:failed)
      expect(workflow.to_state[:last_failed_step][:error_message]).to include("cannot run from state")
    end

    it "continues a delay to its to: state once due" do
      klass = with_stubbed_class("SpecWaitDelayWorkflow", workflow_class) do
        initial_state :throttled
        transition(:cool_off, from: :throttled, to: :requested) { delay 600 }
        transition(:retry_request, from: :requested, to: :done) { compute { |_step| nil } }
      end
      workflow = klass.new.tap(&:run!)
      wait = workflow.awaiting

      expect(wait.to_h).to include(kind: :delay, event: nil, into: nil)
      expect(workflow.resume!(event: :anything, token: wait.token, payload: {})).to eq(:stale)
      expect(workflow.expire_wait!(token: wait.token, now: wait.deadline_at)).to eq(:expired)
      expect(workflow.state).to eq(:requested)
      expect(workflow.run!.state).to eq(:done)
    end
  end

  describe "persistence" do
    it "round-trips a wait and restores a waiting run in strict mode" do
      klass = review_workflow("SpecWaitStrictWorkflow", sent, mode: :strict)
      wait = run_until_waiting(klass).awaiting

      restored = klass.restore("review-1", adapter:)

      expect(restored.awaiting).to eq(wait)
      expect(restored.to_state[:step_in_progress]).to be(false)
      expect(restored.run_persisted!("review-1", adapter:).steps).to be_empty
    end

    it "refuses a malformed wait, an undeclared awaited transition, or a transition of another kind" do
      klass = review_workflow("SpecWaitMalformedWorkflow", sent)
      run_until_waiting(klass)
      payload = JSON.parse(adapter.fetch("review-1"))
      wait = payload.fetch("awaiting")

      [wait.merge("token" => "short"), wait.merge("kind" => "sleep"), wait.merge("deadline_at" => "soon"),
       wait.merge("event" => nil), "not a wait"].each do |bad|
        expect { klass.from_state(payload.merge("awaiting" => bad)) }.to raise_error(Smith::SerializationError)
      end
      [wait.merge("transition" => "removed"), wait.merge("transition" => "finish"),
       wait.merge("kind" => "delay", "event" => nil, "into" => nil)].each do |bad|
        expect { klass.from_state(payload.merge("awaiting" => bad)) }.to raise_error(Smith::UnknownTransitionOnRestore)
      end
      expect { klass.from_state(payload.merge("active_seconds" => -1)) }.to raise_error(Smith::SerializationError)
    end

    it "does not count time spent waiting toward wall_clock" do
      klass = with_stubbed_class("SpecWaitWallClockWorkflow", workflow_class) do
        initial_state :idle
        budget wall_clock: 1
        state :failed
        transition :wait, from: :idle, to: :waited do
          await :ev, into: :reply, timeout: 86_400
          on_timeout :late
        end
        transition :late, from: :idle, to: :late
        transition(:finish, from: :waited, to: :done) do
          compute { |_step| nil }
          on_failure :fail
        end
      end
      workflow = klass.new.tap(&:run!)
      token = workflow.awaiting.token
      later = Time.now.utc + 7_200
      allow(Time).to receive(:now).and_return(later)

      workflow.resume!(event: :ev, token:, payload: { "ok" => true })

      expect(workflow.run!.state).to eq(:done)
    end
  end

  describe "where waits cannot run" do
    it "fails the parent's step when an in-process nested workflow reaches a wait, keeping its usage" do
      child = review_workflow("SpecWaitChildWorkflow", sent)
      parent = with_stubbed_class("SpecWaitParentWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :delegate, from: :idle, to: :done do
          workflow child
          on_failure :fail
        end
      end

      result = parent.new(context: { source_ref: "doc" }).run!

      expect(result.state).to eq(:failed)
      expect(result.last_error.message).to include("in-process child cannot wait")
    end

    it "refuses to prepare an await as a split step, or any step while the run waits" do
      klass = with_stubbed_class("SpecWaitSplitWorkflow", workflow_class) do
        definition_digest Digest::SHA256.hexdigest("spec-wait-split")
        idempotency_mode :strict
        initial_state :idle
        transition :wait, from: :idle, to: :done do
          await :ev, into: :reply, timeout: 60
          on_timeout :late
        end
        transition :late, from: :idle, to: :late
      end

      expect { klass.new.prepare_persisted_step!("split-1", adapter:) }
        .to raise_error(Smith::WorkflowError, /does not run steps that wait or launch runs/)
      waiting = klass.new.tap(&:run!)
      expect { waiting.prepare_persisted_step!("split-2", adapter:) }.to raise_error(Smith::WorkflowError, /waits/)
    end
  end

  describe "delivery before the wait is stored" do
    def early_workflow(name, mode, deliveries)
      deliveries_ref = deliveries
      with_stubbed_class(name, workflow_class) do
        idempotency_mode mode
        initial_state :requested
        state :failed
        transition :fetch_source, from: :requested, to: :fetched do
          await :source_ready, into: :source, timeout: 3_600 do |step|
            deliveries_ref << step.await_token
          end
          on_failure :fail
        end
      end
    end

    %i[lax strict].each do |mode|
      it "completes the await at once in #{mode} mode, and the run that was entering it loses the store" do
        deliveries = []
        klass = early_workflow("SpecWaitEarly#{mode.capitalize}Workflow", mode, deliveries)
        store = adapter
        klass.class_exec do
          define_method(:fast_reply) do |token|
            self.class.resume!("early-1", event: :source_ready, token:, payload: { "fast" => true }, adapter: store)
          end
        end
        replies = []
        hook = ->(token) { replies << klass.allocate.send(:fast_reply, token) }
        klass.find_transition(:fetch_source).await_config[:block].define_singleton_method(:call) do |step|
          deliveries << step.await_token
          hook.call(step.await_token)
        end

        expect { klass.new.advance_persisted!("early-1", adapter:) }.to raise_error(Smith::PersistenceVersionConflict)

        expect(replies).to eq([:resumed])
        stored = klass.restore("early-1", adapter:)
        expect(stored.state).to eq(:fetched)
        expect(stored).not_to be_waiting
        expect(stored.to_state[:context][:source]).to eq(fast: true)
      end
    end

    it "refuses an early delivery that carries the right token under another event" do
      deliveries = []
      klass = early_workflow("SpecWaitEarlyWrongEventWorkflow", :lax, deliveries)
      store = adapter
      replies = []
      klass.find_transition(:fetch_source).await_config[:block].define_singleton_method(:call) do |step|
        replies << klass.resume!("early-2", event: :other_event, token: step.await_token, payload: {}, adapter: store)
      end

      klass.new.advance_persisted!("early-2", adapter:)

      expect(replies).to eq([:stale])
      expect(klass.restore("early-2", adapter:)).to be_waiting
    end

    it "still refuses a strict run caught mid-step for any other delivery" do
      klass = review_workflow("SpecWaitBusyWorkflow", sent, mode: :strict)
      run_until_waiting(klass)
      payload = JSON.parse(adapter.fetch("review-1")).merge("awaiting" => nil, "step_in_progress" => true)
      adapter.store("review-1", JSON.generate(payload))

      expect { klass.resume!("review-1", event: :source_ready, token: "0" * 64, payload: {}, adapter:) }
        .to raise_error(Smith::StepInProgressOnRestore)
    end
  end

  describe "review fixes" do
    it "charges a step that raised or died to wall_clock when the run is restored" do
      crash = self.crash
      klass = with_stubbed_class("SpecWaitChargedWorkflow", workflow_class) do
        initial_state :idle
        budget wall_clock: 5
        transition(:work, from: :idle, to: :done) { compute { |_step| raise crash } }
      end
      expect { klass.new.advance_persisted!("charged-1", adapter:) }.to raise_error(crash)
      stored = JSON.parse(adapter.fetch("charged-1"))
      expect(stored["active_step_started_at"]).to be_a(String)

      started = Time.iso8601(stored["active_step_started_at"])
      allow(Time).to receive(:now).and_return(started + 3)
      expect(klass.restore("charged-1", adapter:).to_state[:active_seconds]).to be_within(0.01).of(3)
      allow(Time).to receive(:now).and_return(started + 60)
      restored = klass.restore("charged-1", adapter:)
      expect(restored.to_state[:active_seconds]).to eq(5)
      expect(restored.to_state[:active_step_started_at]).to be_nil
    end

    it "clears the step mark once a step finishes, and never charges a finished run" do
      klass = review_workflow("SpecWaitClearedMarkWorkflow", sent)
      run_until_waiting(klass)

      expect(JSON.parse(adapter.fetch("review-1"))["active_step_started_at"]).to be_nil

      stepped = with_stubbed_class("SpecWaitClearedAdvanceWorkflow", workflow_class) do
        initial_state :idle
        transition(:work, from: :idle, to: :half) { compute { |_step| nil } }
        transition(:more, from: :half, to: :done) { compute { |_step| nil } }
      end
      stepped.new.advance_persisted!("cleared-1", adapter:)
      expect(JSON.parse(adapter.fetch("cleared-1"))).to include("state" => "half", "active_step_started_at" => nil)
    end

    it "keeps a waiting run that is in a state with no transitions out from being terminal or cleared" do
      klass = with_stubbed_class("SpecWaitRoutedWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition(:prep, from: :idle, to: :parked) do
          compute { |_step| nil }
          on_success :ask
        end
        transition :ask, from: nil, to: :done do
          await :reply, into: :reply, timeout: 60
          on_failure :fail
        end
      end

      klass.run_persisted!(key: "routed-1", adapter:, clear: :terminal)

      expect(adapter.fetch("routed-1")).not_to be_nil
      restored = klass.restore("routed-1", adapter:)
      expect(restored).to be_waiting
      expect(restored.pending_transition_name).to eq(:ask)
    end

    it "reports a waiting run as stuck only once its deadline has passed by the threshold" do
      klass = review_workflow("SpecWaitStuckWorkflow", sent)
      wait = run_until_waiting(klass).awaiting
      store = Class.new(Smith::PersistenceAdapters::Memory) { undef_method :last_heartbeat }.new
      store.store("review-1", adapter.fetch("review-1"))

      allow(Time).to receive(:now).and_return(wait.deadline_at - 10)
      expect(klass.stuck_for?(persistence_key: "review-1", threshold: 60, adapter: store)).to be(false)
      allow(Time).to receive(:now).and_return(wait.deadline_at + 120)
      expect(klass.stuck_for?(persistence_key: "review-1", threshold: 60, adapter: store)).to be(true)
    end

    it "refuses resume! and expire_wait! on an adapter that cannot check versions" do
      klass = review_workflow("SpecWaitUnversionedWorkflow", sent)
      store = Class.new do
        def store(*) = nil
        def fetch(*) = nil
        def delete(*) = nil
      end.new

      expect { klass.resume!("k", event: :source_ready, token: "0" * 64, payload: {}, adapter: store) }
        .to raise_error(Smith::WorkflowError, /store_versioned/)
      expect { klass.expire_wait!("k", token: "0" * 64, adapter: store) }.to raise_error(Smith::WorkflowError)
    end

    it "lets one completion at a time claim a wait" do
      workflow = run_until_waiting(review_workflow("SpecWaitClaimWorkflow", sent))
      wait = workflow.awaiting
      racing = []
      subscription = Smith::Events.on(Smith::Events::StepCompleted) do |_event|
        racing << workflow.expire_wait!(token: wait.token, now: wait.deadline_at + 1)
      end

      expect(workflow.resume!(event: :source_ready, token: wait.token, payload: {})).to eq(:resumed)
      expect(racing).to eq([:stale])
      expect(workflow.to_state[:step_count]).to eq(1)
    ensure
      subscription&.cancel
    end

    it "completes waits one after another on one instance" do
      klass = with_stubbed_class("SpecWaitTwiceWorkflow", workflow_class) do
        initial_state :idle
        transition(:pause, from: :idle, to: :paused) { delay 5 }
        transition :ask, from: :paused, to: :done do
          await :reply, into: :reply, timeout: 60
          on_failure :fail
        end
      end
      workflow = klass.new.tap(&:run!)

      expect(workflow.expire_wait!(token: workflow.awaiting.token, now: workflow.awaiting.deadline_at)).to eq(:expired)
      workflow.run!
      expect(workflow.resume!(event: :reply, token: workflow.awaiting.token, payload: {})).to eq(:resumed)
      expect(workflow.state).to eq(:done)
    end

    it "restores a timed-out failure as WaitTimedOut, with the wait it names" do
      klass = review_workflow("SpecWaitTimedOutRestoreWorkflow", sent, no_timeout_route: true, on_failure: true)
      wait = run_until_waiting(klass).awaiting

      klass.expire_wait!("review-1", token: wait.token, now: wait.deadline_at, adapter:)
      result = klass.restore("review-1", adapter:).run!

      expect(result.last_error).to be_a(Smith::WaitTimedOut)
      expect(result.last_error.details).to eq(transition: "fetch_source", event: "source_ready",
                                              deadline_at: wait.deadline_at.utc.iso8601(6))
    end

    it "emits StepCompleted, ending in the await's own state, when the await times out to on_timeout" do
      completed = []
      subscription = Smith::Events.on(Smith::Events::StepCompleted) { |event| completed << [event.transition, event.to] }
      workflow = run_until_waiting(review_workflow("SpecWaitTimeoutEventWorkflow", sent))
      wait = workflow.awaiting

      expect(workflow.expire_wait!(token: wait.token, now: (wait.deadline_at + 1).iso8601)).to eq(:expired)

      expect(completed).to eq([%i[fetch_source requested]])
      expect { workflow.expire_wait!(token: wait.token, now: 5) }.to raise_error(ArgumentError, /now:/)
    ensure
      subscription&.cancel
    end

    it "reports :failed when delivering a payload takes the failure path" do
      context = Class.new(Smith::Context) { persist :source }
      klass = review_workflow("SpecWaitFailedResumeWorkflow", sent, on_failure: true)
      klass.context_manager(context)
      workflow = klass.new(context: { source_ref: "doc" }).tap(&:run!)
      context.instance_variable_set(:@persist_keys, [:other])

      expect(workflow.resume!(event: :source_ready, token: workflow.awaiting.token, payload: {})).to eq(:failed)
      expect(workflow.run!.state).to eq(:failed)
    end

    it "copies a resolved payload when resolve! is called" do
      payload = { "status" => +"ok" }
      klass = with_stubbed_class("SpecWaitResolveCopyWorkflow", workflow_class) do
        initial_state :idle
        transition :ask, from: :idle, to: :done do
          await(:ev, into: :reply, timeout: 60) do |step|
            step.resolve!(payload)
            payload["status"] << "-changed"
          end
          on_failure :fail
        end
      end
      workflow = klass.new

      workflow.run!

      expect(workflow.to_state[:context][:reply]).to eq(status: "ok")
    end

    it "refuses a wait longer than the store's TTL, before the block sends anything" do
      klass = review_workflow("SpecWaitTtlWorkflow", sent)
      klass.persistence_ttl(60)

      expect { klass.new(context: { source_ref: "doc" }).run_persisted!("ttl-1", adapter:) }
        .to raise_error(Smith::WorkflowError, /persistence TTL/)
      expect(sent).to be_empty
    end

    it "flags a nested workflow that reaches a wait in readiness" do
      child = review_workflow("SpecWaitNestedChildWorkflow", sent)
      parent = with_stubbed_class("SpecWaitNestedParentWorkflow", workflow_class) do
        initial_state :idle
        transition(:delegate, from: :idle, to: :done) { workflow child }
      end

      expect(parent.graph.runtime_readiness.diagnostics.map(&:code)).to include(:nested_workflow_waits)
    end

    it "refuses a stored wait the run's position or the class no longer matches" do
      klass = review_workflow("SpecWaitDriftWorkflow", sent)
      run_until_waiting(klass)
      payload = JSON.parse(adapter.fetch("review-1"))
      wait = payload.fetch("awaiting")

      [payload.merge("next_transition_name" => "finish"),
       payload.merge("awaiting" => wait.merge("deadline_at" => "2000-01-01T00:00:00Z")),
       payload.merge("awaiting" => wait.merge("entered_at" => wait["entered_at"].delete_suffix("Z"),
                                              "deadline_at" => wait["deadline_at"].delete_suffix("Z")))].each do |bad|
        expect { klass.from_state(bad) }.to raise_error(Smith::SerializationError)
      end
      [payload.merge("state" => "fetched"), payload.merge("awaiting" => wait.merge("event" => "renamed")),
       payload.merge("awaiting" => wait.merge("into" => "renamed"))].each do |bad|
        expect { klass.from_state(bad) }.to raise_error(Smith::UnknownTransitionOnRestore)
      end
    end

    it "keeps the stored wait from being changed through awaiting or to_state" do
      workflow = run_until_waiting(review_workflow("SpecWaitFrozenWorkflow", sent))

      expect { workflow.awaiting.token << "x" }.to raise_error(FrozenError)
      expect { workflow.to_state[:awaiting]["deadline_at"] << "x" }.to raise_error(FrozenError)
    end
  end

  describe "graph inspection" do
    it "shows each wait and reaches its timeout route" do
      klass = review_workflow("SpecWaitGraphWorkflow", sent)
      snapshot = klass.graph.transition_snapshots.find { _1.name == :fetch_source }.to_h

      expect(snapshot).to include(kind: :await, timeout_transition: :source_unavailable,
                                  wait: { kind: :await, event: :source_ready, into: :source, timeout: 3_600 })
      expect(klass.graph.reachable_transitions.map(&:name)).to include(:source_unavailable)
    end

    it "shows a delay and a callable timeout, and checks the timeout route's target" do
      klass = with_stubbed_class("SpecWaitDelayGraphWorkflow", workflow_class) do
        initial_state :idle
        transition(:pause, from: :idle, to: :ready) { delay ->(_context) { 5 } }
        transition :ask, from: :ready, to: :done do
          await :ev, into: :reply, timeout: 5
          on_timeout :missing
        end
      end

      kinds = klass.graph.transition_snapshots.to_h { [_1.name, _1.to_h[:kind]] }
      expect(kinds).to include(pause: :delay, ask: :await)
      expect(klass.graph.transition_snapshots.find { _1.name == :pause }.to_h[:wait]).to include(timeout: :callable)
      expect(klass.graph.validate.diagnostics.map(&:code)).to include(:unresolved_timeout_transition)
    end
  end
end
