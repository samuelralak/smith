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
  def charging(name, mode: :lax, errors: [SpecDurableTransient], route: :fail, **policy, &body)
    policy = { attempts: 3, backoff: 30 }.merge(policy)
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
        retry_on(*errors, **policy, durable: true)
        on_failure route
      end
      transition :stray, from: :elsewhere, to: :failed
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
      expect { declare.call(proc { retry_on attempts: 2, backoff: 1, durable: true }) }
        .to raise_error(Smith::WorkflowError, /durable: needs on_failure/)
      expect { declare.call(proc { retry_on attempts: 2, backoff: 1, durable: "yes" }) }
        .to raise_error(Smith::WorkflowError, /durable: must be true or false/)
      [{ attempts: 1, backoff: 1 }, { attempts: 2, backoff: 0, jitter: 5 }].each do |policy|
        expect { declare.call(proc { retry_on(**policy, durable: true) }) }
          .to raise_error(Smith::WorkflowError, /at least 2 attempts and a positive backoff/), policy.inspect
      end
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
          retry_on attempts: 2, backoff: 1, durable: true
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
      expect(workflow.to_state[:pending_retry])
        .to eq("transition" => "charge", "attempt" => 2, "key_generation" => 0, "error" => "SpecDurableTransient")
      expect([wait.attempt, wait.error]).to eq([2, "SpecDurableTransient"])
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
      expect(result.last_error.message).to match(/does not end within the persistence TTL of 300 seconds/)
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
    it "refuses a malformed pending retry, and one the class no longer allows like an unknown position" do
      klass = charging("SpecDurableRestoreWorkflow", &fail_until(1))
      waiting = klass.new.tap { _1.run_persisted!("restore-1", adapter:) }.to_state
      pending = waiting[:pending_retry]
      expect(klass.from_state(JSON.parse(JSON.generate(waiting)))).to be_waiting

      [nil, "x", pending.merge("attempt" => 1), pending.merge("attempt" => "2"),
       pending.merge("key_generation" => 2), pending.merge("key_generation" => -1),
       pending.merge("key_generation" => "0"), pending.merge("transition" => "other"), pending.merge("extra" => 1),
       pending.except("error"), pending.merge("error" => ""), pending.merge("error" => "E" * 257),
       pending.merge("error" => :SpecDurableTransient)].each do |bad|
        expect { klass.from_state(waiting.merge(pending_retry: bad)) }
          .to raise_error(Smith::SerializationError), bad.inspect
      end
      expect { klass.from_state(waiting.merge(pending_retry: pending.merge("attempt" => 4))) }
        .to raise_error(Smith::UnknownTransitionOnRestore)
      longest = klass.from_state(waiting.merge(pending_retry: pending.merge("error" => "E" * 256)))
      expect(longest.awaiting.error).to eq("E" * 256)

      expire(klass, "restore-1")
      due = klass.restore("restore-1", adapter:).to_state
      expect(due).to include(next_transition_name: :charge)
      expect { klass.from_state(due.merge(next_transition_name: nil)) }.to raise_error(Smith::SerializationError)

      undeclared = with_stubbed_class("SpecDurableRestoreWorkflow", workflow_class) do
        initial_state :idle
        transition(:charge, from: :idle, to: :done) { compute { |_s| nil } }
      end
      expect { undeclared.from_state(waiting) }.to raise_error(Smith::UnknownTransitionOnRestore)
      expect { undeclared.from_state(due) }.to raise_error(Smith::UnknownTransitionOnRestore)
    end
  end

  describe "review fixes" do
    def traced
      memory = Smith::Trace::Memory.new
      original = Smith.config.trace_adapter
      Smith.configure { |config| config.trace_adapter = memory }
      Smith::Trace.reset!
      yield
      memory.traces.select { _1[:type] == :transition }.map { _1[:data] }
    ensure
      Smith.configure { |config| config.trace_adapter = original }
      Smith::Trace.reset!
    end

    it "clears the pending retry of a step whose failure route could not run, so the run restores" do
      raising = charging("SpecDurableRaisingWorkflow", attempts: 2, route: :stray, &fail_until(5))
      raising.new.run_persisted!("raise-1", adapter:)
      expire(raising, "raise-1")
      due = raising.restore("raise-1", adapter:)
      expect { due.run_persisted!("raise-1", adapter:) }.to raise_error(Smith::WorkflowError, /cannot run from state/)
      expect(due.to_state[:pending_retry]).to be_nil
      due.persist!("raise-1", adapter:)
      expect(raising.restore("raise-1", adapter:)).not_to be_waiting
    end

    it "lets one instance wait and expire twice, refreshing updated_at, and traces both ends with the run's key" do
      klass = charging("SpecDurableTwiceWorkflow", &fail_until(2))
      workflow = klass.new
      workflow.instance_variable_set(:@persistence_key, "twice-1")

      data = traced do
        2.times do
          workflow.run!
          wait = workflow.awaiting
          allow(Time).to receive(:now).and_return(wait.deadline_at + 1)
          expect(workflow.expire_wait!(token: wait.token, now: wait.deadline_at)).to eq(:expired)
          expect(Time.iso8601(workflow.to_state[:updated_at])).to be >= wait.deadline_at
          allow(Time).to receive(:now).and_call_original
        end
        expect(workflow.run!.state).to eq(:done)
      end

      retrying = data.select { _1[:outcome] == :retrying }
      expect(retrying.map { [_1[:attempt], _1[:error], _1[:execution_key]] })
        .to eq([[2, "SpecDurableTransient", "twice-1"], [3, "SpecDurableTransient", "twice-1"]])
      expect(retrying.map { _1[:deadline_at] }).to all(be_a(String))
      due = data.select { _1[:outcome] == :retry_due }
      expect(due.map { [_1[:attempt], _1[:execution_key]] }).to eq([[2, "twice-1"], [3, "twice-1"]])
    end

    it "passes a nested child's retried error to the parent as the cause, with its usage" do
      child = charging("SpecDurableCauseChild", &fail_until(1))
      parent = with_stubbed_class("SpecDurableCauseParent", workflow_class) do
        initial_state :idle
        state :failed
        transition :delegate, from: :idle, to: :done do
          workflow child
          on_failure :fail
        end
      end

      error = parent.new.run!.last_error

      expect(error).to be_a(Smith::WorkflowError)
      expect(error.cause).to be_a(SpecDurableTransient)
    end

    it "refuses a stored retry wait outside its transition's state, and a wait that reaches the TTL" do
      klass = charging("SpecDurableOriginWorkflow", &fail_until(1))
      waiting = klass.new.tap { _1.run_persisted!("origin-1", adapter:) }.to_state
      expect { klass.from_state(waiting.merge(state: :failed)) }.to raise_error(Smith::UnknownTransitionOnRestore)

      exact = charging("SpecDurableExactWorkflow", backoff: 300, &fail_until(1))
      exact.persistence_ttl(300)
      expect(exact.new.run_persisted!("exact-1", adapter:).last_error.message).to match(/TTL of 300 seconds/)
    end

    it "reports in readiness a backoff that reaches the TTL, and a durable child the launcher runs inline" do
      long = charging("SpecDurableReadyLongWorkflow", attempts: 4, backoff: 60, &fail_until(0))
      long.persistence_ttl(200)
      found = long.graph.runtime_readiness.diagnostics.select { _1.code == :durable_retry_outlasts_ttl }
      expect(found.map { [_1.severity, _1.transition] }).to eq([%i[error charge]])
      expect(found.sole.message).to include("waits up to 240.0 seconds", "TTL of 200 seconds")
      long.persistence_ttl(240)
      expect(long.graph.runtime_readiness.diagnostics.map(&:code)).to include(:durable_retry_outlasts_ttl)
      long.persistence_ttl(241)
      expect(long.graph.runtime_readiness.diagnostics.map(&:code)).not_to include(:durable_retry_outlasts_ttl)
      jittered = with_stubbed_class("SpecDurableReadyJitterWorkflow", workflow_class) do
        initial_state :idle
        persistence_ttl 80
        state :failed
        transition :t, from: :idle, to: :done do
          compute { |_s| nil }
          retry_on attempts: 2, backoff: 60, jitter: 30, durable: true
          on_failure :fail
        end
      end
      expect(jittered.graph.runtime_readiness.diagnostics.map(&:code)).to include(:durable_retry_outlasts_ttl)

      child = charging("SpecDurableInlineChild", &fail_until(0))
      mapper = with_stubbed_class("SpecDurableInlineMap", workflow_class) do
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          map :ids, workflow: child, max_items: 2, timeout: 60, input: ->(id, _ctx) { { id: } }, into: :results
          on_failure :fail
        end
      end
      previous = Smith.config.run_launcher
      Smith.config.run_launcher = Smith::Launchers::Inline.new
      inline = mapper.graph.runtime_readiness.diagnostics.select { _1.code == :nested_workflow_waits }
      expect(inline.sole.message).to include("starts in-process runs of SpecDurableInlineChild")
      Smith.config.run_launcher = Class.new { def launch(**) = nil }.new
      expect(mapper.graph.runtime_readiness.diagnostics.map(&:code)).not_to include(:nested_workflow_waits)
    ensure
      Smith.config.run_launcher = previous
    end

    it "retries a durable agent step, a nesting step, and a from-less step reached through on_failure" do
      calls = 0
      agent = with_stubbed_class("SpecDurableAgent", Smith::Agent) do
        register_as :spec_durable_agent
        model "gpt-5-mini"
      end
      agent.define_singleton_method(:chat) do |**|
        chat = Object.new
        chat.define_singleton_method(:add_message) { |_message| nil }
        chat.define_singleton_method(:with_schema) { |_schema| self }
        chat.define_singleton_method(:complete) do
          calls += 1
          raise Smith::AgentError, "overloaded" if calls == 1

          Struct.new(:content, :input_tokens, :output_tokens).new("drafted", 1, 1)
        end
        chat
      end
      agentic = with_stubbed_class("SpecDurableAgentWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :draft, from: :idle, to: :done do
          execute :spec_durable_agent
          retry_on Smith::AgentError, attempts: 2, backoff: 5, durable: true
          on_failure :fail
        end
      end
      agentic.new.run_persisted!("agent-1", adapter:)
      expect(agentic.restore("agent-1", adapter:).awaiting.error).to eq("Smith::AgentError")
      expire(agentic, "agent-1")
      expect(agentic.restore("agent-1", adapter:).run_persisted!("agent-1", adapter:).output).to eq("drafted")
      expect(calls).to eq(2)

      kid_runs = 0
      kid = with_stubbed_class("SpecDurableKid", workflow_class) do
        initial_state :idle
        transition :work, from: :idle, to: :done do
          compute { |_s| raise SpecDurableTransient if (kid_runs += 1) == 1 }
        end
      end
      flaky = 0
      nesting = with_stubbed_class("SpecDurableNesting", workflow_class) do
        initial_state :idle
        state :failed
        transition :start, from: :idle, to: :checked do
          compute { |_s| raise SpecDurableTransient, "first" if (flaky += 1) == 1 }
          on_failure :recover
        end
        transition :recover, from: nil, to: :done do
          workflow kid
          retry_on SpecDurableTransient, attempts: 2, backoff: 5, durable: true
          on_failure :fail
        end
      end
      nesting.new.run_persisted!("nest-1", adapter:)
      expect(nesting.restore("nest-1", adapter:).awaiting.transition).to eq(:recover)
      expire(nesting, "nest-1")
      expect(nesting.restore("nest-1", adapter:).run_persisted!("nest-1", adapter:).state).to eq(:done)
      expect(kid_runs).to eq(2)
    ensure
      Smith::Agent::Registry.delete(:spec_durable_agent)
    end

    it "keeps the pending retry when the run stops before the retried step starts" do
      workflow = charging("SpecDurableStoppedWorkflow", &fail_until(1)).new
      workflow.run!
      workflow.expire_wait!(token: workflow.awaiting.token, now: workflow.awaiting.deadline_at)
      allow(workflow).to receive(:ensure_transition_budget!).and_raise(Smith::MaxTransitionsExceeded)

      expect { workflow.advance! }.to raise_error(Smith::MaxTransitionsExceeded)
      expect(workflow.to_state[:pending_retry]).to include("attempt" => 2)
    end

    it "refuses to wait inside split-step execution" do
      holder = {}
      klass = charging("SpecDurableSplitExecWorkflow") do |_step|
        holder.fetch(:workflow).instance_variable_set(:@split_step_phase, :executing)
        raise SpecDurableTransient, "busy"
      end
      holder[:workflow] = klass.new

      error = holder[:workflow].advance![:error]

      expect(error.message).to eq("a durable retry cannot wait inside split-step execution")
      expect(holder[:workflow]).not_to be_waiting
    end

    it "pins the graph contract of a policy that is not durable" do
      klass = with_stubbed_class("SpecPlainRetryWorkflow", workflow_class) do
        initial_state :idle
        transition(:t, from: :idle, to: :done) do
          compute { |_s| nil }
          retry_on SpecDurableTransient, attempts: 2, backoff: 1
        end
      end
      config = klass.graph.reachable_transitions.sole.retry_config

      expect(config)
        .to eq(error_classes: [SpecDurableTransient], attempts: 2, backoff: 1.0, max_delay: nil, jitter: 0.0)
      expect(config).to be_frozen
    end
  end
end
