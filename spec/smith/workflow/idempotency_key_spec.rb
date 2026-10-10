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
      expect(attempts.first[1]).to match(/\A\h{64}\z/)
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
      expect(Smith::IdempotencyKey.current_scope).to be_nil
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

    it "gives each optimizer round its own key" do
      generator_keys = []
      stub_key_recording_agent(agent(:spec_idempotency_generator), generator_keys, "draft")
      evaluator = agent(:spec_idempotency_evaluator)
      verdicts = [{ accept: false, converged: false, feedback: "again", score: 0.1 }, { accept: true, score: 0.9 }]
      allow(evaluator).to receive(:chat) { answering_chat(verdicts.shift) }
      klass = with_stubbed_class("SpecIdempotencyOptimizeWorkflow", workflow_class) do
        initial_state :idle

        transition(:draft, from: :idle, to: :done) do
          optimize generator: :spec_idempotency_generator, evaluator: :spec_idempotency_evaluator,
                   max_rounds: 3, evaluator_schema: Class.new
        end
      end

      klass.new.run!

      expect(generator_keys.size).to eq(2)
      expect(generator_keys.uniq.size).to eq(2)
    ensure
      %i[spec_idempotency_generator spec_idempotency_evaluator].each { Smith::Agent::Registry.delete(_1) }
    end

    it "gives each orchestrator round and worker task its own key" do
      orchestrator_keys = []
      decisions = [{ tasks: [{ n: 1 }, { n: 2 }] }, { final: { summary: "done" } }]
      orchestrator = agent(:spec_idempotency_orchestrator)
      allow(orchestrator).to receive(:chat) do
        orchestrator_keys << Smith::IdempotencyKey.current("request")
        answering_chat(decisions.shift)
      end
      stub_key_recording_agent(agent(:spec_idempotency_worker), keys, { finding: "x" })
      klass = with_stubbed_class("SpecIdempotencyOrchestrateWorkflow", workflow_class) do
        initial_state :idle

        transition(:research, from: :idle, to: :done) do
          orchestrate orchestrator: :spec_idempotency_orchestrator, worker: :spec_idempotency_worker,
                      max_workers: 2, max_delegation_rounds: 2, task_schema: SpecIdempotencyLooseSchema,
                      worker_output_schema: SpecIdempotencyLooseSchema, final_output_schema: SpecIdempotencyLooseSchema
        end
      end

      expect(klass.new.run!.state).to eq(:done)

      expect(orchestrator_keys.uniq.size).to eq(2)
      expect(keys.uniq.size).to eq(2)
      expect(orchestrator_keys & keys).to be_empty
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

  describe Smith::IdempotencyKey::Scope do
    let(:scope) { described_class.root("run") }

    it "hashes equal scopes alike whatever their key order or Symbol and String spelling" do
      expect(scope.key({ b: 1, "a" => [1, :x] })).to eq(scope.key({ "a" => [1, "x"], "b" => 1 }))
      expect(scope.key("1")).not_to eq(scope.key(1))
      expect(scope.key(nil)).not_to eq(scope.key(false))
      expect(scope.within(:step, 1, "x").key).not_to eq(scope.within(:step, 2, "x").key)
      expect(described_class.root("other").key).not_to eq(scope.key)
    end

    it "accepts a String in another encoding that converts to UTF-8" do
      expect(scope.key("café".encode("ISO-8859-1"))).to eq(scope.key("café"))
    end

    it "refuses scopes without a stable text form" do
      nested = []
      nested << nested
      [1.5, Object.new, "\xff".b, "\xff".dup.force_encoding("UTF-8"), { a: 1, "a" => 2 }, { 1 => 2 }, nested]
        .each { |bad| expect { scope.key(bad) }.to raise_error(ArgumentError) }
    end

    it "accepts a scope nested to the depth limit" do
      deep = (1..Smith::IdempotencyKey::MAX_SCOPE_DEPTH).reduce("leaf") { |value, _| [value] }

      expect(scope.key(deep)).to match(/\A\h{64}\z/)
      expect { scope.key([deep]) }.to raise_error(ArgumentError, /deeper than/)
    end
  end

  describe "retry_on new_idempotency_key_on:" do
    def declare(**options)
      with_stubbed_class("SpecIdempotencyDeclaredWorkflow#{rand(1_000_000)}", workflow_class) do
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
