# frozen_string_literal: true

require "json"

RSpec.describe "Smith::Workflow durable retry" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:seen) { [] }

  before do
    stub_const("SpecDurableTransient", Class.new(StandardError))
    # A durable retry never sleeps; one that did would hang the suite.
    allow_any_instance_of(workflow_class).to receive(:sleep).and_raise("a durable retry slept")
  end

  # A workflow whose :charge step records each attempt and its key, then
  # runs `body` (failing on the attempts it chooses).
  def charging(name, attempts: 3, backoff: 30, mode: :lax, errors: [SpecDurableTransient], &body)
    recorded = seen
    with_stubbed_class(name, workflow_class) do
      idempotency_mode mode
      initial_state :idle
      state :failed
      transition :charge, from: :idle, to: :done do
        compute do |step|
          recorded << [step.attempt, step.idempotency_key]
          instance_exec(step, &body)
        end
        retry_on(*errors, attempts:, backoff:, durable: true)
        on_failure :fail
      end
    end
  end

  def fail_until(last_failed)
    proc { |step| raise SpecDurableTransient, "busy" if step.attempt <= last_failed }
  end

  def expire(klass, key)
    wait = klass.restore(key, adapter:).awaiting
    klass.expire_wait!(key, token: wait.token, now: wait.deadline_at, adapter:)
  end

  describe "the declaration" do
    it "takes durable: true or false, is refused on steps that wait or keep branch state, and shows in the graph" do
      klass = workflow_class
      declare = lambda do |body|
        Class.new(klass) { transition(:t, from: :a, to: :b) { instance_exec(&body) } }
      end

      schema = Struct.new(:required_keys).new([:accept])
      expect { declare.call(proc { retry_on attempts: 2, durable: "yes" }) }
        .to raise_error(Smith::WorkflowError, /durable: must be true or false/)
      refused = [
        proc do
          await :reply, into: :reply, timeout: 60
          on_failure :fail
        end,
        proc { delay 60 },
        proc { execute :spec_a, parallel: true, count: 2 },
        proc { fan_out(branches: { a: :spec_a, b: :spec_b }) },
        proc { optimize generator: :spec_g, evaluator: :spec_e, max_rounds: 2, evaluator_schema: schema },
        proc do
          orchestrate orchestrator: :spec_o, worker: :spec_w, max_workers: 2, max_delegation_rounds: 2,
                      task_schema: schema, worker_output_schema: schema, final_output_schema: schema
        end
      ]
      refused.each do |step|
        body = proc do
          instance_exec(&step)
          retry_on attempts: 2, durable: true
        end
        expect { declare.call(body) }.to raise_error(Smith::WorkflowError, /durable: is not available/)
      end

      graph = charging("SpecDurableShownWorkflow", &fail_until(0)).graph
      snapshot = graph.transition_snapshots.find { _1.name == :charge }.to_h
      expect(snapshot[:retry_policy]).to include(durable: true, attempts: 3)
      expect(graph.reachable_transitions.sole.retry_config).to include(durable: true)
    end
  end

  describe "waiting instead of sleeping" do
    it "waits out each backoff as a wait of the run, then makes the next attempt when the host continues it" do
      klass = charging("SpecDurableWaitWorkflow", &fail_until(1))
      workflow = klass.new

      workflow.run_persisted!("charge-1", adapter:)

      wait = workflow.awaiting
      expect([wait.kind, wait.event, wait.into, wait.transition]).to eq([:retry, nil, nil, :charge])
      expect(wait.deadline_at - wait.entered_at).to be_within(0.01).of(30)
      expect([workflow.state, workflow.to_state[:step_count]]).to eq([:idle, 0])
      expect(workflow.to_state[:pending_retry]).to eq("transition" => "charge", "attempt" => 2, "key_generation" => 0)
      expect(klass.restore("charge-1", adapter:).run_persisted!("charge-1", adapter:).steps).to eq([])

      expect(klass.expire_wait!("charge-1", token: wait.token, now: wait.deadline_at - 1, adapter:)).to eq(:not_due)
      expect(klass.resume!("charge-1", event: :retry, token: wait.token, payload: nil, adapter:)).to eq(:stale)
      expect(expire(klass, "charge-1")).to eq(:expired)
      expect(klass.expire_wait!("charge-1", token: wait.token, now: wait.deadline_at, adapter:)).to eq(:stale)

      due = klass.restore("charge-1", adapter:)
      expect([due.waiting?, due.state, due.pending_transition_name]).to eq([false, :idle, :charge])
      result = due.run_persisted!("charge-1", adapter:)

      expect(result.state).to eq(:done)
      expect(seen.map(&:first)).to eq([1, 2])
      expect(seen.map(&:last).uniq.length).to eq(1)
      expect(due.to_state).to include(pending_retry: nil, step_count: 1)
    end

    it "fails for good after its last attempt, through on_failure, each wait under a token of its own" do
      klass = charging("SpecDurableExhaustedWorkflow", attempts: 3, &fail_until(5))
      klass.new.run_persisted!("charge-2", adapter:)
      first = klass.restore("charge-2", adapter:).awaiting
      expect(expire(klass, "charge-2")).to eq(:expired)
      klass.restore("charge-2", adapter:).run_persisted!("charge-2", adapter:)
      second = klass.restore("charge-2", adapter:).awaiting
      expect(second.token).not_to eq(first.token)
      expect(klass.expire_wait!("charge-2", token: first.token, now: second.deadline_at, adapter:)).to eq(:stale)
      expect(expire(klass, "charge-2")).to eq(:expired)

      result = klass.restore("charge-2", adapter:).run_persisted!("charge-2", adapter:)

      expect(result.state).to eq(:failed)
      expect(result.last_error).to be_a(SpecDurableTransient)
      expect(seen.map(&:first)).to eq([1, 2, 3])
      expect(klass.restore("charge-2", adapter:).to_state[:pending_retry]).to be_nil
    end

    it "keeps the step's keys across its waits, and moves to new ones after an attempt it declares settled" do
      klass = charging("SpecDurableKeysWorkflow", attempts: 4, errors: []) do |step|
        step.fail!("timed out", retryable: true) if step.attempt == 1
        step.fail!("declined", retryable: true, new_idempotency_key: true) if step.attempt == 2
        step.fail!("timed out", retryable: true) if step.attempt == 3
      end

      klass.new.run_persisted!("charge-3", adapter:)
      3.times do
        expect(expire(klass, "charge-3")).to eq(:expired)
        klass.restore("charge-3", adapter:).run_persisted!("charge-3", adapter:)
      end

      keys = seen.map(&:last)
      expect(seen.map(&:first)).to eq([1, 2, 3, 4])
      expect([keys[1] == keys[0], keys[2] == keys[1], keys[3] == keys[2]]).to eq([true, false, true])
      expect(klass.restore("charge-3", adapter:).state).to eq(:done)
    end

    it "runs in memory too: the instance waits, and expire_wait! then run! make the next attempt" do
      workflow = charging("SpecDurableMemoryWorkflow", &fail_until(1)).new

      workflow.run!
      expect(workflow).to be_waiting
      expect(workflow.expire_wait!(token: workflow.awaiting.token, now: workflow.awaiting.deadline_at)).to eq(:expired)

      expect(workflow.run!.state).to eq(:done)
      expect(seen.map(&:first)).to eq([1, 2])
    end
  end

  describe "crashes" do
    it "makes the same attempt again under the same key when the run crashed before the step ended" do
      crash = Class.new(Exception) # rubocop:disable Lint/InheritException
      calls = 0
      klass = charging("SpecDurableCrashWorkflow") do |step|
        calls += 1
        raise SpecDurableTransient, "busy" if step.attempt == 1
        raise crash if calls == 2
      end
      klass.new.run_persisted!("charge-4", adapter:)
      expire(klass, "charge-4")

      expect { klass.restore("charge-4", adapter:).run_persisted!("charge-4", adapter:) }.to raise_error(crash)
      expect(klass.restore("charge-4", adapter:).to_state[:pending_retry]).to include("attempt" => 2)
      klass.restore("charge-4", adapter:).run_persisted!("charge-4", adapter:)

      expect(seen.map(&:first)).to eq([1, 2, 2])
      expect(seen.map(&:last).uniq.length).to eq(1)
    end

    it "in strict mode, refuses to restore a run caught in its retried step" do
      crash = Class.new(Exception) # rubocop:disable Lint/InheritException
      klass = charging("SpecDurableStrictWorkflow", mode: :strict) do |step|
        raise SpecDurableTransient, "busy" if step.attempt == 1

        raise crash
      end
      klass.new.run_persisted!("charge-5", adapter:)
      expire(klass, "charge-5")

      expect { klass.restore("charge-5", adapter:).run_persisted!("charge-5", adapter:) }.to raise_error(crash)
      expect { klass.restore("charge-5", adapter:) }.to raise_error(Smith::StepInProgressOnRestore)
    end
  end

  describe "limits" do
    it "enters no wait past the run's deadline, after a tool ran, or longer than the store keeps the run" do
      late = charging("SpecDurableLateWorkflow") do |_step|
        Kernel.sleep 0.2
        raise SpecDurableTransient, "busy"
      end
      late.budget(wall_clock: 0.1)
      spent = late.new
      expect(spent.run_persisted!("late-1", adapter:).last_error).to be_a(SpecDurableTransient)
      expect(spent).not_to be_waiting

      tooled = charging("SpecDurableToolWorkflow") do |_step|
        Smith::Tool.current_tool_execution_tracker.mark_started!
        raise SpecDurableTransient, "busy"
      end
      result = tooled.new.run_persisted!("tool-1", adapter:)
      expect(result.last_error).to be_a(Smith::ToolOutcomeUncertain)
      expect(tooled.restore("tool-1", adapter:)).not_to be_waiting

      long = charging("SpecDurableLongWorkflow", backoff: 600, &fail_until(1))
      long.persistence_ttl(300)
      result = long.new.run_persisted!("long-1", adapter:)
      expect(result.last_error.message).to match(/outlasts the persistence TTL of 300 seconds/)
      expect(long.restore("long-1", adapter:)).not_to be_waiting
    end

    it "fails the parent's step from an in-process nested workflow, which readiness reports, and is never split" do
      child = charging("SpecDurableChildWorkflow", &fail_until(1))
      parent = with_stubbed_class("SpecDurableParentWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :delegate, from: :idle, to: :done do
          workflow child
          on_failure :fail
        end
      end

      expect(parent.new.run!.last_error.message).to match(/durable retry\); an in-process child cannot wait/)
      expect(parent.graph.runtime_readiness.diagnostics.map(&:code)).to include(:nested_workflow_waits)

      split = charging("SpecDurableSplitWorkflow", &fail_until(0))
      split.definition_digest(Digest::SHA256.hexdigest("spec-durable-split"))
      split.idempotency_mode(:strict)
      expect { split.new.prepare_persisted_step!("split-1", adapter:) }
        .to raise_error(Smith::WorkflowError, /does not run steps that wait or launch runs/)
    end
  end

  describe "restore" do
    it "refuses a pending retry that does not fit the run or the policy, and a retry wait without one" do
      klass = charging("SpecDurableRestoreWorkflow", &fail_until(1))
      waiting = klass.new.tap { _1.run_persisted!("restore-1", adapter:) }.to_state
      pending = waiting[:pending_retry]
      expect(klass.from_state(JSON.parse(JSON.generate(waiting)))).to be_waiting

      [nil, "x", pending.merge("attempt" => 1), pending.merge("attempt" => 4), pending.merge("attempt" => "2"),
       pending.merge("key_generation" => 2), pending.merge("key_generation" => -1),
       pending.merge("key_generation" => "0"),
       pending.merge("transition" => "other"), pending.merge("extra" => 1)].each do |bad|
        expect { klass.from_state(waiting.merge(pending_retry: bad)) }
          .to raise_error(Smith::SerializationError), bad.inspect
      end

      expire(klass, "restore-1")
      due = klass.restore("restore-1", adapter:).to_state
      expect(due).to include(next_transition_name: :charge)
      expect { klass.from_state(due.merge(next_transition_name: nil)) }.to raise_error(Smith::SerializationError)

      undeclared = with_stubbed_class("SpecDurableRestoreWorkflow", workflow_class) do
        initial_state :idle
        transition(:charge, from: :idle, to: :done) { compute { |_s| nil } }
      end
      expect { undeclared.from_state(waiting) }.to raise_error(Smith::UnknownTransitionOnRestore)
      expect { undeclared.from_state(due) }.to raise_error(Smith::SerializationError)
    end
  end
end
