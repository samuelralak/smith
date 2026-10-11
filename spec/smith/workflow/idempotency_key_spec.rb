# frozen_string_literal: true

require "json"

SpecIdempotencyLooseSchema = Class.new { def self.required_keys = [] }

RSpec.describe "Smith idempotency keys" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:tool_class) { require_const("Smith::Tool") }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:keys) { [] }

  # Stands in for a process dying mid-step: not a StandardError, so no
  # retry or failure route sees it and the post-step checkpoint never runs.
  let(:crash) { Class.new(Exception) } # rubocop:disable Lint/InheritException

  def recording_step_workflow(name, keys, &body)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle

      transition(:first, from: :idle, to: :middle) { compute { |step| keys << step.idempotency_key } }
      transition(:second, from: :middle, to: :done) do
        compute { |step| body ? body.call(step) : keys << step.idempotency_key }
      end
    end
  end

  def answering_chat(content)
    chat = Object.new
    chat.define_singleton_method(:add_message) { |_message| nil }
    chat.define_singleton_method(:with_schema) { |_schema| self }
    chat.define_singleton_method(:complete) { Struct.new(:content, :input_tokens, :output_tokens).new(content, 1, 1) }
    chat
  end

  def stub_key_recording_agent(klass, keys, content)
    allow(klass).to receive(:chat) do
      keys << Smith::IdempotencyKey.current("request")
      answering_chat(content)
    end
  end

  def agent(name)
    with_stubbed_class("Spec#{name.to_s.split("_").map(&:capitalize).join}", agent_class) do
      register_as name
      model "gpt-5-mini"
    end
  end

  describe "in a compute step" do
    it "is a 64-character hex key, the same on every attempt, and differs by scope and step" do
      keys = self.keys
      klass = with_stubbed_class("SpecIdempotencyRetryWorkflow", workflow_class) do
        initial_state :idle

        transition :charge, from: :idle, to: :charged do
          compute do |step|
            keys << [step.attempt, step.idempotency_key, step.idempotency_key("refund")]
            step.fail!("timed out", retryable: true) if step.attempt < 3
          end
          retry_on attempts: 3
        end
        transition(:notify, from: :charged, to: :done) do
          compute { |step| keys << [step.attempt, step.idempotency_key] }
        end
      end
      klass.new.run!

      attempts = keys.first(3)
      expect(attempts.map(&:first)).to eq([1, 2, 3])
      expect(attempts.map { _1[1] }.uniq.size).to eq(1)
      expect(attempts.first[1]).to match(/\A[0-9a-f]{64}\z/)
      expect(attempts.first[2]).not_to eq(attempts.first[1])
      expect(keys.last[1]).not_to eq(attempts.first[1])
    end

    it "keeps a step's keys when the run is restored after a crash mid-step" do
      crash = self.crash
      calls = 0
      klass = recording_step_workflow("SpecIdempotencyCrashWorkflow", keys) do |step|
        keys << step.idempotency_key
        calls += 1
        raise crash if calls == 1
      end
      workflow = klass.new
      workflow.advance_persisted!("run-1", adapter:)
      expect { workflow.advance_persisted!("run-1", adapter:) }.to raise_error(crash)

      klass.restore("run-1", adapter:).advance_persisted!("run-1", adapter:)

      expect(keys.size).to eq(3)
      expect(keys[2]).to eq(keys[1])
      expect(keys[1]).not_to eq(keys[0])
    end

    it "gives a new run new keys, even under a persistence key an earlier run used" do
      klass = recording_step_workflow("SpecIdempotencyRerunWorkflow", keys)

      klass.run_persisted!(key: "run-1", adapter:)
      klass.run_persisted!(key: "run-1", adapter:)

      expect(keys.size).to eq(4)
      expect(keys.first(2)).not_to include(*keys.last(2))
    end

    it "moves to a new key after an attempt the step declares settled, and keeps it after a timeout" do
      keys = self.keys
      klass = with_stubbed_class("SpecIdempotencySettledWorkflow", workflow_class) do
        initial_state :idle

        transition :charge, from: :idle, to: :done do
          compute do |step|
            keys << step.idempotency_key
            step.fail!("timed out", retryable: true) if step.attempt == 1
            step.fail!("declined", retryable: true, new_idempotency_key: true) if step.attempt == 2
            step.fail!("timed out", retryable: true) if step.attempt == 3
          end
          retry_on attempts: 4
        end
      end
      klass.new.run!

      expect(keys.size).to eq(4)
      expect(keys[1]).to eq(keys[0])
      expect(keys[2]).not_to eq(keys[1])
      expect(keys[3]).to eq(keys[2])
    end

    it "moves to a new key after an error retry_on names in new_idempotency_key_on" do
      keys = self.keys
      declined = Class.new(StandardError)
      timed_out = Class.new(StandardError)
      stub_const("SpecIdempotencyDeclined", declined)
      stub_const("SpecIdempotencyTimedOut", timed_out)
      klass = with_stubbed_class("SpecIdempotencyRetryOnWorkflow", workflow_class) do
        initial_state :idle

        transition :charge, from: :idle, to: :done do
          compute do |step|
            keys << step.idempotency_key
            raise SpecIdempotencyTimedOut if step.attempt == 1
            raise SpecIdempotencyDeclined if step.attempt == 2
          end
          retry_on SpecIdempotencyDeclined, SpecIdempotencyTimedOut, attempts: 3,
                                                                     new_idempotency_key_on: [SpecIdempotencyDeclined]
        end
      end
      klass.new.run!

      expect(keys[1]).to eq(keys[0])
      expect(keys[2]).not_to eq(keys[1])
    end

    it "places a nested workflow's steps under the parent's step" do
      keys = self.keys
      child = recording_step_workflow("SpecIdempotencyChildWorkflow", keys)
      parent = with_stubbed_class("SpecIdempotencyParentWorkflow", workflow_class) do
        initial_state :idle

        transition(:first, from: :idle, to: :middle) { compute { |step| keys << step.idempotency_key } }
        transition(:second, from: :middle, to: :done) { workflow child }
      end

      parent.new.run!

      expect(keys.size).to eq(3)
      expect(keys.uniq.size).to eq(3)
    end

    it "gives a transition that runs again later in the run a new key" do
      keys = self.keys
      klass = with_stubbed_class("SpecIdempotencyLoopWorkflow", workflow_class) do
        initial_state :idle

        transition :tick, from: :idle, to: :ticked do
          compute(routes: %i[again finish]) do |step|
            keys << step.idempotency_key
            step.route_to(keys.size < 2 ? :again : :finish)
          end
        end
        transition(:again, from: :ticked, to: :idle) { compute { |_step| nil } }
        transition(:finish, from: :ticked, to: :done) { compute { |_step| nil } }
      end

      klass.new.run!

      expect(keys.size).to eq(2)
      expect(keys.uniq.size).to eq(2)
      expect(Smith::IdempotencyKey.__send__(:current_scope)).to be_nil
    end

    it "keys a workflow advanced inside another's step as a run of its own" do
      keys = self.keys
      inner_class = recording_step_workflow("SpecIdempotencyInnerWorkflow", keys)
      inner = inner_class.new
      checkpoint = JSON.parse(JSON.generate(inner.to_state))
      outer_class = with_stubbed_class("SpecIdempotencyOuterWorkflow", workflow_class) do
        initial_state :idle

        transition(:drive, from: :idle, to: :done) { compute { |_step| inner.advance! } }
      end

      outer_class.new.run!
      inner_class.from_state(checkpoint).advance!

      expect(keys.size).to eq(2)
      expect(keys.last).to eq(keys.first)
    end

    it "keeps a first attempt's key whether or not the step declares retry_on" do
      keys = self.keys
      plain = recording_step_workflow("SpecIdempotencyPlainWorkflow", keys)
      retrying = with_stubbed_class("SpecIdempotencyRetryingWorkflow", workflow_class) do
        initial_state :idle

        transition(:first, from: :idle, to: :middle) do
          compute { |step| keys << step.idempotency_key }
          retry_on attempts: 2
        end
      end
      checkpoint = JSON.parse(JSON.generate(plain.new.to_state))

      plain.from_state(checkpoint).advance!
      retrying.from_state(checkpoint).advance!

      expect(keys.size).to eq(2)
      expect(keys.last).to eq(keys.first)
    end

    it "keeps the outer step's position after a workflow it advanced finishes its step" do
      keys = self.keys
      inner = recording_step_workflow("SpecIdempotencyAdvancedWorkflow", keys).new
      outer = with_stubbed_class("SpecIdempotencyAdvancingWorkflow", workflow_class) do
        initial_state :idle

        transition(:drive, from: :idle, to: :done) do
          compute do |_step|
            keys << Smith::IdempotencyKey.current
            inner.advance!
            keys << Smith::IdempotencyKey.current
          end
        end
      end

      outer.new.run!

      expect(keys.size).to eq(3)
      expect(keys.last).to eq(keys.first)
    end

    it "refuses a new_idempotency_key flag that is not true or false" do
      step = Smith::Workflow::DeterministicStep.new(context: {}, session_messages: [], tool_results: [], state: :idle,
                                                    transition_name: :x)

      expect { step.fail!("declined", new_idempotency_key: "yes") }.to raise_error(ArgumentError, /true or false/)
      expect { Smith::DeterministicStepFailure.new("declined", new_idempotency_key: "yes") }
        .to raise_error(ArgumentError, /true or false/)
      expect { step.fail!("declined", new_idempotency_key: true) }
        .to raise_error(Smith::DeterministicStepFailure) { |error| expect(error.new_idempotency_key).to be(true) }
    end

    it "is refused outside a running step" do
      step = Smith::Workflow::DeterministicStep.new(context: {}, session_messages: [], tool_results: [], state: :idle,
                                                    transition_name: :x)

      expect { step.idempotency_key }
        .to raise_error(Smith::WorkflowError, /only available inside a running workflow step/)
      expect { Smith::IdempotencyKey.current }.to raise_error(Smith::WorkflowError)
      expect(step.attempt).to eq(1)
    end
  end

  describe "the run's namespace" do
    it "is assigned at construction and given on restore to a payload written without one" do
      klass = recording_step_workflow("SpecIdempotencyNamespaceWorkflow", keys)
      payload = JSON.parse(JSON.generate(klass.new.to_state))
      expect(payload["execution_namespace"]).to match(/\A\h{8}-/)

      restored = klass.from_state(payload.merge("execution_namespace" => nil))

      expect(restored.to_state[:execution_namespace]).to match(/\A\h{8}-/)
    end
  end

  describe "branches, rounds and tasks" do
    it "gives each parallel branch its own key" do
      stub_key_recording_agent(agent(:spec_idempotency_parallel_agent), keys, "ok")
      klass = with_stubbed_class("SpecIdempotencyParallelWorkflow", workflow_class) do
        initial_state :idle

        transition(:fan, from: :idle, to: :done) { execute :spec_idempotency_parallel_agent, parallel: true, count: 3 }
      end

      klass.new.run!

      expect(keys.size).to eq(3)
      expect(keys.uniq.size).to eq(3)
    ensure
      Smith::Agent::Registry.delete(:spec_idempotency_parallel_agent)
    end

    it "gives each fan-out branch its own key" do
      %i[spec_idempotency_fan_a spec_idempotency_fan_b].each { stub_key_recording_agent(agent(_1), keys, "ok") }
      klass = with_stubbed_class("SpecIdempotencyFanoutWorkflow", workflow_class) do
        initial_state :idle

        transition(:fan, from: :idle, to: :done) do
          fan_out branches: { a: :spec_idempotency_fan_a, b: :spec_idempotency_fan_b }
        end
      end

      klass.new.run!

      expect(keys.uniq.size).to eq(2)
    ensure
      %i[spec_idempotency_fan_a spec_idempotency_fan_b].each { Smith::Agent::Registry.delete(_1) }
    end

    it "gives each optimizer round, and the generator and evaluator in it, their own key" do
      generator_keys = []
      evaluator_keys = []
      stub_key_recording_agent(agent(:spec_idempotency_generator), generator_keys, "draft")
      evaluator = agent(:spec_idempotency_evaluator)
      verdicts = [{ accept: false, converged: false, feedback: "again", score: 0.1 }, { accept: true, score: 0.9 }]
      allow(evaluator).to receive(:chat) do
        evaluator_keys << Smith::IdempotencyKey.current("request")
        answering_chat(verdicts.shift)
      end
      klass = with_stubbed_class("SpecIdempotencyOptimizeWorkflow", workflow_class) do
        initial_state :idle

        transition(:draft, from: :idle, to: :done) do
          optimize generator: :spec_idempotency_generator, evaluator: :spec_idempotency_evaluator,
                   max_rounds: 3, evaluator_schema: Class.new
        end
      end

      klass.new.run!

      expect(generator_keys.size).to eq(2)
      expect((generator_keys + evaluator_keys).uniq.size).to eq(4)
    ensure
      %i[spec_idempotency_generator spec_idempotency_evaluator].each { Smith::Agent::Registry.delete(_1) }
    end

    def stub_task_recording_worker(task_keys)
      allow(agent(:spec_idempotency_worker)).to receive(:chat) do
        chat = answering_chat({ finding: "x" })
        chat.define_singleton_method(:add_message) { |message| @task = message[:content] }
        chat.define_singleton_method(:complete) do
          task_keys << [@task, Smith::IdempotencyKey.current("request")]
          Struct.new(:content, :input_tokens, :output_tokens).new({ finding: "x" }, 1, 1)
        end
        chat
      end
    end

    def orchestrated_workflow(name, decisions, task_keys)
      allow(agent(:spec_idempotency_orchestrator)).to receive(:chat) { answering_chat(decisions.shift) }
      stub_task_recording_worker(task_keys)
      with_stubbed_class(name, workflow_class) do
        initial_state :idle

        transition(:research, from: :idle, to: :done) do
          orchestrate orchestrator: :spec_idempotency_orchestrator, worker: :spec_idempotency_worker,
                      max_workers: 2, max_delegation_rounds: 3, task_schema: SpecIdempotencyLooseSchema,
                      worker_output_schema: SpecIdempotencyLooseSchema, final_output_schema: SpecIdempotencyLooseSchema
        end
      end
    end

    it "keys an orchestrator's worker task by its content, so a replay that reorders tasks keeps each one's key" do
      task_keys = []
      decisions = [{ tasks: [{ to: "a" }, { to: "b" }] }, { final: { summary: "done" } },
                   { tasks: [{ to: "b" }, { to: "a" }] }, { final: { summary: "done" } }]
      klass = orchestrated_workflow("SpecIdempotencyReorderWorkflow", decisions, task_keys)
      checkpoint = JSON.parse(JSON.generate(klass.new.to_state))

      2.times { expect(klass.from_state(checkpoint).run!.state).to eq(:done) }

      first, replay = task_keys.each_slice(2).map(&:to_h)
      expect(replay).to eq(first)
      expect(first.values.uniq.size).to eq(2)
    ensure
      %i[spec_idempotency_orchestrator spec_idempotency_worker].each { Smith::Agent::Registry.delete(_1) }
    end

    it "gives equal tasks in one round, and a task repeated in a later round, their own keys" do
      task_keys = []
      decisions = [{ tasks: [{ to: "a" }, { to: "a" }] }, { tasks: [{ to: "a" }] }, { final: { summary: "done" } }]

      expect(orchestrated_workflow("SpecIdempotencyRepeatWorkflow", decisions, task_keys).new.run!.state).to eq(:done)

      expect(task_keys.map(&:last).uniq.size).to eq(3)
    ensure
      %i[spec_idempotency_orchestrator spec_idempotency_worker].each { Smith::Agent::Registry.delete(_1) }
    end
  end

  describe "durable composite branches" do
    def prepare_composite(workflow_class, key)
      workflow = workflow_class.new
      workflow.prepare_persisted_step!(key, adapter:)
      [workflow.claim_prepared_step_dispatch!, workflow.prepare_composite_step!]
    end

    def execute_branches(workflow_class, dispatch, preparation)
      preparation.plan.branches.map do |branch|
        workflow = workflow_class.recover_prepared_step(Smith::Workflow::PreparedStepRecovery.not_started(dispatch),
                                                        adapter:)
        workflow.execute_prepared_composite_branch!(execution: preparation.plan.execution_for(branch),
                                                    input: preparation.input)
      end
    end

    it "gives each branch its own key, the same when a worker runs the branch again" do
      agent = Class.new(Smith::Agent) { model "gpt-5-mini" }
      agent.execution_identity(Digest::SHA256.hexdigest("spec-idempotency-composite-agent"))
      Smith::Agent::Registry.register(:spec_idempotency_composite_agent, agent)
      stub_key_recording_agent(agent, keys, "ok")
      workflow_class = stub_const("SpecIdempotencyCompositeWorkflow", Class.new(Smith::Workflow) do
        definition_digest Digest::SHA256.hexdigest("spec-idempotency-composite")
        idempotency_mode :strict
        initial_state :idle
        transition(:fan, from: :idle, to: :done) { execute :spec_idempotency_composite_agent, parallel: true, count: 2 }
      end)
      dispatch, preparation = prepare_composite(workflow_class, "composite:keys")

      2.times { expect(execute_branches(workflow_class, dispatch, preparation)).to all(be_succeeded) }

      expect(keys.size).to eq(4)
      expect(keys.first(2).uniq.size).to eq(2)
      expect(keys.last(2)).to eq(keys.first(2))
    ensure
      Smith::Agent::Registry.delete(:spec_idempotency_composite_agent)
    end
  end

  describe "in a tool" do
    let(:keyed_tool) do
      with_stubbed_class("SpecIdempotencyKeyedTool", tool_class) do
        def perform(**kwargs) = idempotency_key(kwargs)
      end
    end

    def run_tool_calls(tool, calls)
      chat = Smith::Tool::ChatExecutionContext.install(SpecToolExecutionChat.new(keyed: tool))
      call = Data.define(:name, :arguments)
      tool_calls = calls.each_with_index.to_h { |arguments, index| [index, call.new(name: :keyed, arguments:)] }
      chat.run_concurrently(tool_calls).map(&:last)
    end

    it "gives each request its own key, carried into concurrent tool calls, apart from the step's own key" do
      tool = keyed_tool.new
      results = []
      run_calls = method(:run_tool_calls)
      klass = with_stubbed_class("SpecIdempotencyToolWorkflow", workflow_class) do
        initial_state :idle

        transition(:call, from: :idle, to: :done) do
          compute do |step|
            results << step.idempotency_key
            results.concat(run_calls.call(tool, [{ to: "a" }, { to: "b" }, { to: "a" }]))
          end
        end
      end

      klass.new.run!

      step_key, first, second, repeat = results
      expect([first, second].uniq.size).to eq(2)
      expect(repeat).to eq(first)
      expect([first, second]).not_to include(step_key)
    end

    it "gives two tools sending the same scope different keys" do
      other_tool = with_stubbed_class("SpecIdempotencyOtherKeyedTool", tool_class) do
        def perform(**kwargs) = idempotency_key(kwargs)
      end.new
      tool = keyed_tool.new
      results = []
      run_calls = method(:run_tool_calls)
      klass = with_stubbed_class("SpecIdempotencyTwoToolsWorkflow", workflow_class) do
        initial_state :idle

        transition(:call, from: :idle, to: :done) do
          compute do |_step|
            results.concat(run_calls.call(tool, [{ to: "a" }]))
            results.concat(run_calls.call(other_tool, [{ to: "a" }]))
          end
        end
      end

      klass.new.run!

      expect(results.uniq.size).to eq(2)
    end

    it "is refused outside a workflow step" do
      expect { keyed_tool.new.send(:idempotency_key, {}) }.to raise_error(Smith::WorkflowError)
    end
  end

  describe "review fixes" do
    it "keeps a parent's keys when a nested workflow's step declares its own failure settled" do
      keys = self.keys
      calls = 0
      child = with_stubbed_class("SpecIdempotencySettledChildWorkflow", workflow_class) do
        initial_state :idle

        transition(:charge, from: :idle, to: :charged) { compute { |step| keys << step.idempotency_key } }
        transition :notify, from: :charged, to: :done do
          compute do |step|
            calls += 1
            step.fail!("refused", retryable: true, new_idempotency_key: true) if calls == 1
          end
        end
      end
      parent = with_stubbed_class("SpecIdempotencySettledParentWorkflow", workflow_class) do
        initial_state :idle

        transition :delegate, from: :idle, to: :done do
          workflow child
          retry_on attempts: 2
        end
      end

      expect(parent.new.run!.state).to eq(:done)

      expect(keys.size).to eq(2)
      expect(keys.last).to eq(keys.first)
    end

    it "refuses new_idempotency_key_on on a transition whose failures can come from several steps or branches" do
      bodies = [
        -> { workflow Class.new(Smith::Workflow) },
        -> { execute :spec_agent, parallel: true, count: 2 },
        -> { fan_out branches: { a: :spec_a, b: :spec_b } },
        -> { optimize generator: :g, evaluator: :e, max_rounds: 2, evaluator_schema: Class.new },
        lambda do
          orchestrate orchestrator: :o, worker: :w, max_workers: 1, max_delegation_rounds: 1,
                      task_schema: SpecIdempotencyLooseSchema, worker_output_schema: SpecIdempotencyLooseSchema,
                      final_output_schema: SpecIdempotencyLooseSchema
        end
      ]
      bodies.each do |body|
        [true, false].each do |retry_first|
          expect do
            Class.new(workflow_class) do
              initial_state :idle
              transition(:go, from: :idle, to: :done) do
                retry_on ArgumentError, attempts: 2, new_idempotency_key_on: [ArgumentError] if retry_first
                instance_exec(&body)
                retry_on ArgumentError, attempts: 2, new_idempotency_key_on: [ArgumentError] unless retry_first
              end
            end
          end.to raise_error(Smith::WorkflowError, /new_idempotency_key_on/)
        end
      end
    end

    it "derives the same namespace on every restore of a payload written without one" do
      klass = recording_step_workflow("SpecIdempotencyLegacyWorkflow", keys)
      payload = JSON.parse(JSON.generate(klass.new.to_state)).merge("execution_namespace" => nil)

      first = klass.from_state(payload).to_state[:execution_namespace]
      second = klass.from_state(payload).to_state[:execution_namespace]

      expect(first).to eq(second)
      expect(first).to match(Smith::Workflow::PreparedStep::UUID_PATTERN)
      other = klass.from_state(payload.merge("created_at" => "2020-01-01T00:00:00.000000Z"))
      expect(other.to_state[:execution_namespace]).not_to eq(first)
    end

    it "keeps no position out of event handlers and on_step callbacks" do
      seen = []
      subscription = Smith::Events.on(Smith::Events::StepCompleted) do |_event|
        seen << Smith::IdempotencyKey.__send__(:current_scope)
      end
      klass = recording_step_workflow("SpecIdempotencyEventWorkflow", keys)

      on_step = ->(_step) { seen << Smith::IdempotencyKey.__send__(:current_scope) }
      klass.new.run_persisted!("events-1", adapter:, on_step:)

      expect(seen.size).to eq(4)
      expect(seen).to all(be_nil)
    ensure
      subscription&.cancel
    end

    it "refuses a restored execution namespace that is not a UUID" do
      klass = recording_step_workflow("SpecIdempotencyMalformedWorkflow", keys)
      payload = JSON.parse(JSON.generate(klass.new.to_state))

      ["", 42, { "a" => 1 }, "not-a-uuid"].each do |bad|
        expect { klass.from_state(payload.merge("execution_namespace" => bad)) }
          .to raise_error(Smith::SerializationError, /execution_namespace/)
      end
    end

    it "keeps a fresh run's first-step key across a crash in that step" do
      keys = self.keys
      crash = self.crash
      klass = with_stubbed_class("SpecIdempotencyFirstStepWorkflow", workflow_class) do
        initial_state :idle

        transition :send_it, from: :idle, to: :done do
          compute do |step|
            keys << step.idempotency_key
            raise crash if keys.size == 1
          end
        end
      end

      expect { klass.new.advance_persisted!("first-1", adapter:) }.to raise_error(crash)
      klass.restore("first-1", adapter:).advance_persisted!("first-1", adapter:)

      expect(keys.size).to eq(2)
      expect(keys.last).to eq(keys.first)
    end

    it "persists a legacy payload's derived namespace before the step that uses it" do
      klass = recording_step_workflow("SpecIdempotencyLegacyPersistWorkflow", keys)
      klass.new.advance_persisted!("legacy-1", adapter:)
      legacy = JSON.parse(adapter.fetch("legacy-1")).merge("execution_namespace" => nil)
      adapter.store("legacy-1", JSON.generate(legacy))

      restored = klass.restore("legacy-1", adapter:)
      derived = restored.to_state[:execution_namespace]
      restored.advance_persisted!("legacy-1", adapter:)

      expect(JSON.parse(adapter.fetch("legacy-1"))["execution_namespace"]).to eq(derived)
    end

    it "refuses a tool key for a tool without a name" do
      unnamed = Class.new(tool_class) { def perform(**kwargs) = idempotency_key(kwargs) }.new
      unnamed.define_singleton_method(:name) { "" }
      results = []
      klass = with_stubbed_class("SpecIdempotencyUnnamedToolWorkflow", workflow_class) do
        initial_state :idle
        transition(:call, from: :idle, to: :done) do
          compute do |_step|
            unnamed.send(:idempotency_key, {})
          rescue Smith::WorkflowError => e
            results << e
          end
        end
      end

      klass.new.run!

      expect(results.sole).to be_a(Smith::WorkflowError)
    end

    it "gives a durable composite preparation's input guardrails the step's position" do
      seen = []
      guardrails = Class.new(Smith::Guardrails) do
        input :record
        define_method(:record) { |_payload| seen << Smith::IdempotencyKey.__send__(:current_scope) }
      end
      agent = Class.new(Smith::Agent) { model "gpt-5-mini" }
      agent.guardrails(guardrails)
      agent.execution_identity(Digest::SHA256.hexdigest("spec-idempotency-guarded-agent"))
      Smith::Agent::Registry.register(:spec_idempotency_guarded_agent, agent)
      workflow_class = stub_const("SpecIdempotencyGuardedWorkflow", Class.new(Smith::Workflow) do
        definition_digest Digest::SHA256.hexdigest("spec-idempotency-guarded")
        idempotency_mode :strict
        initial_state :idle
        transition(:fan, from: :idle, to: :done) { execute :spec_idempotency_guarded_agent, parallel: true, count: 2 }
      end)
      workflow = workflow_class.new
      workflow.prepare_persisted_step!("composite:guarded", adapter:)
      workflow.claim_prepared_step_dispatch!

      workflow.prepare_composite_step!

      expect(seen).not_to be_empty
      expect(seen).to all(be_truthy)
    ensure
      Smith::Agent::Registry.delete(:spec_idempotency_guarded_agent)
    end

    it "keeps on_step callbacks free of the enclosing step's position when a run is advanced inside another's step" do
      seen = []
      inner_class = recording_step_workflow("SpecIdempotencyInnerCallbackWorkflow", keys)
      store = adapter
      on_step = ->(_step) { seen << Smith::IdempotencyKey.__send__(:current_scope) }
      outer = with_stubbed_class("SpecIdempotencyOuterCallbackWorkflow", workflow_class) do
        initial_state :idle

        transition(:drive, from: :idle, to: :done) do
          compute { |_step| inner_class.new.run_persisted!("inner-callback-1", adapter: store, on_step:) }
        end
      end

      outer.new.run!

      expect(seen.size).to eq(2)
      expect(seen).to all(be_nil)
    end

    it "derives keys from a fixed layout of positions, which must not change between releases" do
      namespace = "00000000-0000-4000-8000-000000000000"
      root = Smith::IdempotencyKey.__send__(:root_scope, namespace)
      expected = lambda do |*segments, scope: "request"|
        segments.reduce(root) { |scope_so_far, segment| scope_so_far.within(*segment) }.key(scope)
      end
      generator_keys = []
      evaluator_keys = []
      stub_key_recording_agent(agent(:spec_idempotency_generator), generator_keys, "draft")
      evaluator = agent(:spec_idempotency_evaluator)
      allow(evaluator).to receive(:chat) do
        evaluator_keys << Smith::IdempotencyKey.current("request")
        answering_chat({ accept: true, score: 0.9 })
      end
      klass = with_stubbed_class("SpecIdempotencyLayoutWorkflow", workflow_class) do
        initial_state :idle

        transition(:draft, from: :idle, to: :done) do
          optimize generator: :spec_idempotency_generator, evaluator: :spec_idempotency_evaluator,
                   max_rounds: 2, evaluator_schema: Class.new
        end
      end
      payload = JSON.parse(JSON.generate(klass.new.to_state)).merge("execution_namespace" => namespace)

      klass.from_state(payload).run!

      expect(generator_keys).to eq([expected.call([:step, 1, "draft"], [:round, 0], [:generator])])
      expect(evaluator_keys).to eq([expected.call([:step, 1, "draft"], [:round, 0], [:evaluator])])
      expect(root.within(:step, 1, "draft").key(nil))
        .to eq("75288281b3decd1e2b70067610e6bad2b3dfc39bd9b77026a449d56853f5c4df")
    ensure
      %i[spec_idempotency_generator spec_idempotency_evaluator].each { Smith::Agent::Registry.delete(_1) }
    end

    it "refuses to install anything but a position" do
      expect { Smith::IdempotencyKey.__send__(:install, "not a position") }.to raise_error(ArgumentError)
      expect(Smith::IdempotencyKey.__send__(:current_scope)).to be_nil
    ensure
      Smith::Tool.__send__(:current_idempotency_scope=, nil)
    end

    it "leaves retry_config's shape alone for a policy without new_idempotency_key_on" do
      klass = with_stubbed_class("SpecIdempotencyPlainRetryWorkflow", workflow_class) do
        initial_state :idle
        transition(:go, from: :idle, to: :done) do
          compute { |_step| nil }
          retry_on ArgumentError, attempts: 2
        end
      end

      expect(klass.find_transition(:go).retry_config).not_to have_key(:new_idempotency_key_on)
    end
  end

  describe "scope canonicalization" do
    let(:scope) { Smith::IdempotencyKey.__send__(:root_scope, "run") }

    it "hashes equal scopes alike whatever their key order or Symbol and String spelling" do
      expect(scope.key({ b: 1, "a" => [1, :x] })).to eq(scope.key({ "a" => [1, "x"], "b" => 1 }))
      expect(scope.key("1")).not_to eq(scope.key(1))
      expect(scope.key(nil)).not_to eq(scope.key(false))
      expect(scope.within(:step, 1, "x").key).not_to eq(scope.within(:step, 2, "x").key)
      expect(Smith::IdempotencyKey.__send__(:root_scope, "other").key).not_to eq(scope.key)
    end

    it "accepts a String in another encoding that converts to UTF-8" do
      expect(scope.key("café".encode("ISO-8859-1"))).to eq(scope.key("café"))
    end

    it "refuses scopes without a stable text form" do
      nested = []
      nested << nested
      [Float::NAN, Float::INFINITY, Rational(1, 2), Object.new, "\xff".b, "\xff".dup.force_encoding("UTF-8"),
       { a: 1, "a" => 2 }, { 1 => 2 }, nested]
        .each { |bad| expect { scope.key(bad) }.to raise_error(ArgumentError) }
    end

    it "keys a Float by its value, so a whole Float equals the Integer a model's JSON may send instead" do
      expect(scope.key({ amount: 12.0 })).to eq(scope.key({ amount: 12 }))
      expect(scope.key(-0.0)).to eq(scope.key(0))
      expect(scope.key(12.5)).not_to eq(scope.key(12))
      expect(scope.key(12.5)).not_to eq(scope.key("12.5"))
      expect(scope.key(0.1 + 0.2)).not_to eq(scope.key(0.3))
    end

    it "bounds the values it reads, so shared subtrees cannot cost exponential time" do
      shared = (1..20).reduce(["leaf"]) { |node, _| [node, node] }
      wide = Array.new(Smith::IdempotencyKey::MAX_SCOPE_NODES - 1, 1)

      expect { scope.key(shared) }.to raise_error(ArgumentError, /more than/)
      expect(scope.key(wide)).to match(/\A[0-9a-f]{64}\z/)
      expect { scope.key(wide + [1]) }.to raise_error(ArgumentError, /more than/)
    end

    it "takes position segments only from Strings, Symbols and Integers, as frozen copies" do
      label = +"charge"
      narrowed = scope.within(:step, 1, label)
      key = narrowed.key
      label << "-changed"

      expect(narrowed.key).to eq(key)
      [Object.new, 1.5, nil].each { |bad| expect { scope.within(:step, bad) }.to raise_error(ArgumentError) }
    end

    it "accepts a scope nested to the depth limit" do
      deep = (1..Smith::IdempotencyKey::MAX_SCOPE_DEPTH).reduce("leaf") { |value, _| [value] }

      expect(scope.key(deep)).to match(/\A[0-9a-f]{64}\z/)
      expect { scope.key([deep]) }.to raise_error(ArgumentError, /deeper than/)
    end
  end

  describe "retry_on new_idempotency_key_on:" do
    def declare(**options)
      @declared = (@declared || 0) + 1
      with_stubbed_class("SpecIdempotencyDeclaredWorkflow#{@declared}", workflow_class) do
        initial_state :idle

        transition(:go, from: :idle, to: :done) do
          compute { |_step| nil }
          retry_on(*options.delete(:classes), **options)
        end
      end
    end

    it "shows in graph inspection only when declared" do
      klass = declare(classes: [ArgumentError, IOError], attempts: 2, new_idempotency_key_on: [ArgumentError])

      expect(klass.graph.transition_snapshots.sole.to_h[:retry_policy])
        .to include(new_idempotency_key_on: ["ArgumentError"])
      expect(declare(classes: [], attempts: 2).graph.transition_snapshots.sole.to_h[:retry_policy])
        .not_to have_key(:new_idempotency_key_on)
    end

    it "refuses classes the policy does not retry, non-classes and uncertain tool outcomes" do
      expect { declare(classes: [IOError], attempts: 2, new_idempotency_key_on: [ArgumentError]) }
        .to raise_error(Smith::WorkflowError, /does not retry/)
      expect { declare(classes: [], attempts: 2, new_idempotency_key_on: ArgumentError) }
        .to raise_error(Smith::WorkflowError, /Array of StandardError classes/)
      [["ArgumentError"], [Exception]].each do |bad|
        expect { declare(classes: [], attempts: 2, new_idempotency_key_on: bad) }
          .to raise_error(Smith::WorkflowError, /Array of StandardError classes/)
      end
      expect { declare(classes: [], attempts: 2, new_idempotency_key_on: [Smith::ToolOutcomeUncertain]) }
        .to raise_error(Smith::WorkflowError, /uncertain/)
    end

    it "refuses a class listed twice" do
      expect { declare(classes: [], attempts: 2, new_idempotency_key_on: [ArgumentError, ArgumentError]) }
        .to raise_error(Smith::WorkflowError, /more than once/)
    end

    it "accepts a subclass of a retried class, and any class when Smith's classification decides retries" do
      expect(declare(classes: [StandardError], attempts: 2, new_idempotency_key_on: [ArgumentError])).to be_a(Class)
      expect(declare(classes: [], attempts: 2, new_idempotency_key_on: [ArgumentError])).to be_a(Class)
    end

    it "is part of the transition contract graph inspection returns" do
      klass = declare(classes: [], attempts: 2, new_idempotency_key_on: [ArgumentError])

      expect(klass.graph.reachable_transitions.sole.retry_config).to include(new_idempotency_key_on: [ArgumentError])
      expect(declare(classes: [], attempts: 2).graph.reachable_transitions.sole.retry_config)
        .not_to have_key(:new_idempotency_key_on)
    end
  end
end
