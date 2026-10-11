# frozen_string_literal: true

require "json"

RSpec.describe "Smith::Workflow child runs: map, call and spawn" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:launches) { [] }

  # A launcher that records each launch and returns nothing, as a queueing
  # host launcher would.
  let(:recording_launcher) do
    recorded = launches
    Class.new { define_method(:launch) { |**call| recorded << call and nil } }.new
  end

  around do |example|
    previous = Smith.config.run_launcher
    example.run
  ensure
    Smith.config.run_launcher = previous
  end

  def child(name = "SpecChildRunWorkflow", &body)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      transition(:work, from: :idle, to: :done) { compute { |_step| nil } }
      class_exec(&body) if body
    end
  end

  def parent(name, child_class, collect: :outputs, on_item_failure: :fail, max_items: 5)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      transition :fan, from: :idle, to: :mapped do
        map :ids, workflow: child_class, max_items:, timeout: 60, collect:, on_item_failure:,
                  input: ->(id, ctx) { { id:, topic: ctx[:topic] } }, into: :results
        on_failure :fail
      end
      transition(:finish, from: :mapped, to: :done) { compute { |_step| nil } }
    end
  end

  def entry(ref, status = "succeeded", output = "out #{ref}") = { ref:, status:, state: "done", output: }

  describe "the DSL" do
    it "validates its settings, needs a timeout route for map and call, and takes valid ones" do
      kid = child
      klass = workflow_class
      declare = lambda do |body, route: true|
        Class.new(klass) do
          transition(:t, from: :a, to: :b) do
            instance_exec(&body)
            on_failure :fail if route
          end
        end
      end
      input = ->(*) { {} }
      map_options = { workflow: kid, max_items: 1, input:, timeout: 1, into: :r }
      bad = [
        map_options.merge(workflow: String), map_options.merge(max_items: 0), map_options.merge(max_items: 10_001),
        map_options.merge(input: {}), map_options.merge(timeout: 0), map_options.merge(into: "r"),
        map_options.merge(collect: :all), map_options.merge(on_item_failure: :x), map_options.merge(extra: 1),
        map_options.except(:into)
      ]

      bad.each do |options|
        expect { declare.call(proc { map(:ids, **options) }) }.to raise_error(Smith::WorkflowError), options.inspect
      end
      expect { declare.call(proc { map("ids", **map_options) }) }.to raise_error(Smith::WorkflowError)
      expect { declare.call(proc { map(:ids, **map_options) }, route: false) }
        .to raise_error(Smith::WorkflowError, /on_timeout or on_failure/)
      expect { declare.call(proc { call(kid, input:, timeout: 1, into: :r, max_items: 2) }) }
        .to raise_error(Smith::WorkflowError)
      spawn_and_compute = proc do
        spawn(:ids, workflow: kid, max_items: 1, input:)
        compute { |_s| nil }
      end
      expect { declare.call(spawn_and_compute, route: false) }.to raise_error(Smith::WorkflowError)

      expect { declare.call(proc { map(:ids, **map_options, max_items: 10_000) }) }.not_to raise_error
      expect { declare.call(proc { call(kid, input:, timeout: 1, into: :r) }) }.not_to raise_error
      expect { declare.call(proc { spawn(:ids, workflow: kid, max_items: 1, input:) }, route: false) }
        .not_to raise_error
    end
  end

  describe "map" do
    it "launches one child per item, waits, and writes their results when the host resumes it" do
      Smith.config.run_launcher = recording_launcher
      klass = parent("SpecMapWorkflow", child)
      workflow = klass.new(context: { ids: %w[a b], topic: "t" })
      workflow.run_persisted!("map-1", adapter:)

      launch = launches.sole
      expect(launch[:parent_key]).to eq("map-1")
      expect(launch[:await_token]).to eq(workflow.awaiting.token)
      expect(launch[:children].map { [_1.ref, _1.workflow, _1.input] })
        .to eq([[0, klass.find_transition(:fan).children_config[:workflow], { id: "a", topic: "t" }],
                [1, klass.find_transition(:fan).children_config[:workflow], { id: "b", topic: "t" }]])
      expect(workflow.awaiting.kind).to eq(:children)

      results = [entry(1), entry(0)]
      expect(klass.resume!("map-1", event: :children, token: workflow.awaiting.token, payload: results, adapter:))
        .to eq(:resumed)
      resumed = klass.restore("map-1", adapter:)
      expect(resumed.to_state[:context][:results]).to eq([entry(0), entry(1)])
      expect(resumed.state).to eq(:mapped)
    end

    it "collects states or counts instead of outputs" do
      Smith.config.run_launcher = recording_launcher
      { states: [entry(0).except(:output), entry(1, "failed").except(:output)],
        none: { succeeded: 1, failed: 1 } }.each do |collect, written|
        klass = parent("SpecMap#{collect.capitalize}Workflow", child, collect:, on_item_failure: :collect)
        workflow = klass.new(context: { ids: %w[a b] }).tap { _1.run_persisted!("map-#{collect}", adapter:) }

        klass.resume!("map-#{collect}", event: :children, token: workflow.awaiting.token,
                                        payload: [entry(0), entry(1, "failed")], adapter:)

        expect(klass.restore("map-#{collect}", adapter:).to_state[:context][:results]).to eq(written)
      end
    end

    it "fails the step through on_failure when a child failed, and the failure persists with its refs" do
      Smith.config.run_launcher = recording_launcher
      klass = parent("SpecMapFailedWorkflow", child)
      workflow = klass.new(context: { ids: %w[a b c] }).tap { _1.run_persisted!("map-f", adapter:) }

      expect(klass.resume!("map-f", event: :children, token: workflow.awaiting.token,
                                    payload: [entry(0), entry(1, "failed"), entry(2, "failed")], adapter:))
        .to eq(:failed)
      error = klass.restore("map-f", adapter:).run!.last_error
      expect(error).to be_a(Smith::ChildRunsFailed)
      expect(error.details).to eq(transition: "fan", failed_refs: [1, 2], failed: 2, total: 3)
      expect(Smith::Workflow::FailureRecord.capture(transition: :fan, from: :idle, to: :mapped, error:))
        .to include(error_family: "child_runs_failed")
    end

    it "refuses results that do not match its children, leaving the run waiting" do
      Smith.config.run_launcher = recording_launcher
      klass = parent("SpecMapMalformedWorkflow", child)
      workflow = klass.new(context: { ids: %w[a b] }).tap { _1.run_persisted!("map-m", adapter:) }
      token = workflow.awaiting.token

      [[entry(0)], [entry(0), entry(0)], [entry(0), entry(2)], [entry(0), entry(1, "maybe")],
       [entry(0), entry(1).merge(extra: 1)], "not a list"].each do |payload|
        expect { klass.resume!("map-m", event: :children, token:, payload:, adapter:) }
          .to raise_error(Smith::WorkflowError), payload.inspect
        expect(klass.restore("map-m", adapter:)).to be_waiting
      end
      expect(klass.resume!("map-m", event: :children, token:, payload: [entry(0), entry(1)], adapter:)).to eq(:resumed)
    end

    it "fails before anything launches past max_items, for items that are not an Array, or in a run not persisted" do
      Smith.config.run_launcher = recording_launcher
      klass = parent("SpecMapBoundsWorkflow", child, max_items: 2)

      expect(klass.new(context: { ids: %w[a b c] }).run!.last_error.message).to match(/more than its max_items of 2/)
      expect(klass.new(context: { ids: "a" }).run!.last_error.message).to match(/items must be an Array/)
      expect(klass.new(context: { ids: %w[a] }).run!.last_error.message).to match(/needs a persisted run/)
      expect(launches).to be_empty
    end

    it "needs a launcher, and an input: that returns a JSON-shaped Hash, which it puts in the context's key shape" do
      Smith.config.run_launcher = nil
      klass = parent("SpecMapNoLauncherWorkflow", child)
      expect(klass.new(context: { ids: %w[a] }).run!.last_error.message).to match(/needs Smith.config.run_launcher/)

      Smith.config.run_launcher = recording_launcher
      kid = child
      shaped = lambda do |input|
        with_stubbed_class("SpecMapInput#{input.object_id}", workflow_class) do
          initial_state :idle
          state :failed
          transition :fan, from: :idle, to: :done do
            map :ids, workflow: kid, max_items: 2, timeout: 60, input: ->(_id, _ctx) { input }, into: :results
            on_failure :fail
          end
        end
      end
      expect(shaped.call([1]).new(context: { ids: [1] }).run!.last_error.message).to match(/input: must return a Hash/)
      expect(shaped.call({ at: Object.new }).new(context: { ids: [1] }).run!.last_error.message)
        .to match(/child run input/)

      shaped.call({ "nested" => { "deep" => 1 } }).new(context: { ids: [1] }).run_persisted!("map-shape", adapter:)
      expect(launches.sole[:children].sole.input).to eq(nested: { deep: 1 })
    end

    it "frees the wait after a malformed delivery to the same instance, and takes results up to 4 MiB" do
      Smith.config.run_launcher = recording_launcher
      klass = parent("SpecMapInstanceWorkflow", child, collect: :none)
      workflow = klass.new(context: { ids: %w[a] }).tap { _1.run_persisted!("map-i", adapter:) }
      token = workflow.awaiting.token

      expect { workflow.resume!(event: :children, token:, payload: []) }.to raise_error(Smith::WorkflowError)
      big = entry(0, "succeeded", "x" * (2 * 1024 * 1024))
      expect(workflow.resume!(event: :children, token:, payload: [big])).to eq(:resumed)
      expect(workflow.to_state[:context][:results]).to eq(succeeded: 1, failed: 0)
    end

    it "launches the same children under the same token when the step is replayed" do
      Smith.config.run_launcher = recording_launcher
      klass = parent("SpecMapReplayWorkflow", child)
      payload = JSON.generate(klass.new(context: { ids: %w[a b] }).to_state)

      2.times { |n| klass.from_state(JSON.parse(payload)).run_persisted!("map-r#{n}", adapter:) }

      expect(launches.map { _1[:await_token] }.uniq.size).to eq(1)
      expect(launches.map { _1[:children].map(&:ref) }).to eq([[0, 1], [0, 1]])
    end

    it "takes its timeout route when its deadline passes, and completes on a delivery before the wait is stored" do
      Smith.config.run_launcher = recording_launcher
      klass = parent("SpecMapTimeoutWorkflow", child)
      workflow = klass.new(context: { ids: %w[a] }).tap { _1.run_persisted!("map-t", adapter:) }
      wait = workflow.awaiting

      expect(klass.expire_wait!("map-t", token: wait.token, now: (wait.deadline_at + 1).iso8601, adapter:))
        .to eq(:expired)
      expect(klass.restore("map-t", adapter:).run!.last_error).to be_a(Smith::WaitTimedOut)

      store = adapter
      early = with_stubbed_class("SpecEarlyLauncher", Object) do
        define_method(:launch) do |parent_key:, await_token:, **|
          klass.resume!(parent_key, event: :children, token: await_token, payload: [{ ref: 0, status: "succeeded",
                                                                                      state: "done", output: 1 }],
                                    adapter: store)
          nil
        end
      end
      Smith.config.run_launcher = early.new
      expect { klass.new(context: { ids: %w[a] }).advance_persisted!("map-e", adapter:) }
        .to raise_error(Smith::PersistenceVersionConflict)
      expect(klass.restore("map-e", adapter:).to_state[:context][:results].sole[:output]).to eq(1)
    end
  end

  describe "call" do
    it "writes the child's output itself, and fails the step when the child failed" do
      Smith.config.run_launcher = recording_launcher
      kid = child
      klass = with_stubbed_class("SpecCallWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :ask, from: :idle, to: :done do
          call kid, input: ->(ctx) { { topic: ctx[:topic] } }, timeout: 60, into: :summary
          on_failure :fail
        end
      end
      workflow = klass.new(context: { topic: "t" }).tap { _1.run_persisted!("call-1", adapter:) }
      expect(launches.sole[:children].map { [_1.ref, _1.input] }).to eq([[0, { topic: "t" }]])

      klass.resume!("call-1", event: :children, token: workflow.awaiting.token,
                              payload: [entry(0, "succeeded", { "text" => "short" })], adapter:)
      expect(klass.restore("call-1", adapter:).to_state[:context][:summary]).to eq(text: "short")

      failing = klass.new(context: { topic: "t" }).tap { _1.run_persisted!("call-2", adapter:) }
      expect(klass.resume!("call-2", event: :children, token: failing.awaiting.token,
                                     payload: [entry(0, "failed")], adapter:)).to eq(:failed)
    end
  end

  describe "spawn" do
    it "launches and continues without waiting" do
      Smith.config.run_launcher = recording_launcher
      kid = child
      klass = with_stubbed_class("SpecSpawnWorkflow", workflow_class) do
        initial_state :idle
        transition :notify, from: :idle, to: :done do
          spawn :ids, workflow: kid, max_items: 3, input: ->(id, _ctx) { { id: } }
        end
      end

      result = klass.new(context: { ids: [1, 2] }).run_persisted!("spawn-1", adapter:)

      expect(result.state).to eq(:done)
      expect(launches.sole[:children].map { [_1.ref, _1.input] }).to eq([[0, { id: 1 }], [1, { id: 2 }]])
      expect(launches.sole[:await_token]).to match(/\A\h{64}\z/)
    end
  end

  describe Smith::Launchers::Inline do
    it "runs the children in process, so the step completes at once, in a run that is not persisted" do
      Smith.config.run_launcher = described_class.new
      kid = child("SpecInlineChild") { transition(:boom, from: :done, to: :never) { compute { |_s| raise "boom" } } }
      klass = parent("SpecInlineWorkflow", kid, on_item_failure: :collect, collect: :states)

      result = klass.new(context: { ids: %w[a b] }).run!

      expect(result.state).to eq(:done)
      expect(result.context[:results].map { _1[:status] }).to all(eq("failed"))
    end
  end

  describe "untrusted keys" do
    it "pass to a child under the same name and persist with it" do
      Smith.config.run_launcher = recording_launcher
      manager = Class.new(Smith::Context) do
        persist :doc, :ids, :results
        untrusted :doc
      end
      kid = child
      klass = with_stubbed_class("SpecUntrustedMapWorkflow", workflow_class) do
        context_manager manager
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          map :ids, workflow: kid, max_items: 2, timeout: 60, input: ->(id, ctx) { { id:, doc: ctx[:doc] } },
                    into: :results
          on_failure :fail
        end
      end
      klass.new(context: { ids: [1], doc: "outside" }).run_persisted!("untrusted-1", adapter:)

      run = launches.sole[:children].sole
      expect(run.untrusted_keys).to eq([:doc])
      built = run.build
      restored = kid.from_state(JSON.parse(JSON.generate(built.to_state)))
      expect(restored.send(:untrusted_context_keys)).to eq([:doc])
      ["doc", [1], [""], Array.new(1_001) { "k#{_1}" }].each do |keys|
        expect { kid.from_state(built.to_state.merge(inherited_untrusted_keys: keys)) }
          .to raise_error(Smith::SerializationError), keys.inspect[0, 40]
      end
    end
  end

  describe "graph inspection and readiness" do
    it "shows the step and its child, reports a missing launcher, and walks the child" do
      Smith.config.run_launcher = nil
      waiting_child = child("SpecWaitingChild") do
        state :failed
        transition :hold, from: :done, to: :held do
          await :reply, into: :reply, timeout: 60
          on_failure :fail
        end
        transition :orphan, from: :nowhere, to: :held
      end
      klass = parent("SpecInspectedWorkflow", waiting_child)

      snapshot = klass.graph.transition_snapshots.find { _1.name == :fan }.to_h
      codes = klass.graph.runtime_readiness.diagnostics.map(&:code)

      expect(snapshot).to include(kind: :map,
                                  children: include(workflow: "SpecWaitingChild",
                                                    items: :ids, max_items: 5))
      expect(codes).to include(:run_launcher_missing, :nested_undefined_from_state)
      expect(codes).not_to include(:nested_workflow_waits)

      Smith.config.run_launcher = recording_launcher
      expect(klass.graph.runtime_readiness.diagnostics.map(&:code)).not_to include(:run_launcher_missing)
    end
  end

  describe Smith::ChildRun do
    it "builds a result entry from a run result" do
      done = Smith::Workflow::RunResult.new(state: :done, output: "x", steps: [])
      failed = Smith::Workflow::RunResult.new(state: :failed, output: nil, steps: [{ error: RuntimeError.new("x") }])

      expect(described_class.result(ref: 3, run_result: done))
        .to eq(ref: 3, status: "succeeded", state: "done", output: "x")
      expect(described_class.result(ref: 4, run_result: failed)[:status]).to eq("failed")
    end
  end

  describe Smith::ChildRunsFailed do
    it "bounds its details and refuses persisted ones out of bounds" do
      error = described_class.new(transition: :fan, failed_refs: (0...30).to_a, total: 40)
      good = { "transition" => "fan", "failed_refs" => [1], "failed" => 1, "total" => 2 }

      expect(error.details).to include(failed_refs: (0...20).to_a, failed: 30, total: 40)
      expect(described_class.from_details(good).failed_refs).to eq([1])
      [good.merge("failed_refs" => (0...21).to_a), good.merge("failed" => 3), good.merge("failed_refs" => ["1"]),
       good.merge("extra" => 1), good.except("total")].each do |bad|
        expect { described_class.from_details(bad) }.to raise_error(ArgumentError), bad.inspect
      end
    end
  end
end
