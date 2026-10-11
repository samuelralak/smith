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
      expect(declare { await :ev, into: :x, timeout: ->(_context) { 5 } }).to be_a(Class)
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
      expect(wait.to_h).to include(kind: :await, event: "source_ready", transition: :fetch_source, into: :source,
                                   token: sent.sole)
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

      expected = Smith::IdempotencyKey.__send__(:root_scope, namespace)
                                      .within(:step, 1, "fetch_source").key(%w[await source_ready])
      expect(workflow.awaiting.token).to eq(expected)
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
      expect(klass.resume!("missing", event: :source_ready, token:, payload: {}, adapter:)).to eq(:stale)
      expect(adapter.fetch("review-1")).to eq(stored)
      expect(klass.new.resume!(event: :source_ready, token:, payload: {})).to eq(:stale)
    end

    it "refuses a payload that is not JSON-shaped and keeps the run waiting" do
      workflow = run_until_waiting(review_workflow("SpecWaitBadPayloadWorkflow", sent))

      expect { workflow.resume!(event: :source_ready, token: workflow.awaiting.token, payload: { at: Object.new }) }
        .to raise_error(Smith::WorkflowError, /wait payload/)
      expect(workflow).to be_waiting
    end

    it "keeps into: within an explicit persist list" do
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
      workflow = klass.new.tap(&:run!)

      expect { workflow.resume!(event: :ev, token: workflow.awaiting.token, payload: {}) }
        .to raise_error(Smith::UndeclaredContextKey)
      expect(workflow).to be_waiting
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

    it "raises and keeps the run waiting when the await has no timeout route at all" do
      workflow = run_until_waiting(review_workflow("SpecWaitNoRouteWorkflow", sent, no_timeout_route: true))
      wait = workflow.awaiting

      expect { workflow.expire_wait!(token: wait.token, now: wait.deadline_at + 1) }
        .to raise_error(Smith::WaitTimedOut)
      expect(workflow).to be_waiting
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
        .to raise_error(Smith::WorkflowError, /does not run await or delay/)
      waiting = klass.new.tap(&:run!)
      expect { waiting.prepare_persisted_step!("split-2", adapter:) }.to raise_error(Smith::WorkflowError, /waits/)
    end
  end

  describe "graph inspection" do
    it "shows each wait, reaches its timeout route, and flags an await with no timeout route" do
      klass = review_workflow("SpecWaitGraphWorkflow", sent)
      snapshot = klass.graph.transition_snapshots.find { _1.name == :fetch_source }.to_h

      expect(snapshot).to include(kind: :await, timeout_transition: :source_unavailable,
                                  wait: { kind: :await, event: :source_ready, into: :source, timeout: 3_600 })
      expect(klass.graph.reachable_transitions.map(&:name)).to include(:source_unavailable)
      expect(klass.graph.validate.diagnostics.map(&:code)).not_to include(:await_without_timeout_route)

      bare = review_workflow("SpecWaitBareGraphWorkflow", sent, no_timeout_route: true)
      expect(bare.graph.validate.diagnostics.map(&:code)).to include(:await_without_timeout_route)
      failing = review_workflow("SpecWaitFailingGraphWorkflow", sent, no_timeout_route: true, on_failure: true)
      expect(failing.graph.validate.diagnostics.map(&:code)).not_to include(:await_without_timeout_route)
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
