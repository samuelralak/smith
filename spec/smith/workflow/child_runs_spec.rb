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
        .to raise_error(Smith::WorkflowError, /must declare on_failure/)
      expect { declare.call(proc { call(kid, input:, timeout: 1, into: :r, max_items: 2) }) }
        .to raise_error(Smith::WorkflowError)
      spawn_and_compute = proc do
        spawn(:ids, workflow: kid, max_items: 1, input:)
        compute { |_s| nil }
      end
      expect { declare.call(spawn_and_compute, route: false) }.to raise_error(Smith::WorkflowError)
      compute_and_map = proc do
        compute { |_s| nil }
        map(:ids, **map_options)
      end
      expect { declare.call(compute_and_map) }.to raise_error(Smith::WorkflowError)

      expect { declare.call(proc { map(:ids, **map_options, max_items: 10_000) }) }.not_to raise_error
      expect { declare.call(proc { call(kid, input:, timeout: 1, into: :r) }) }.not_to raise_error
      expect { declare.call(proc { spawn(:ids, workflow: kid, max_items: 1, input:) }, route: false) }
        .not_to raise_error
      [proc { map(:ids, **map_options) }, proc { call(kid, input:, timeout: 1, into: :r) },
       proc { spawn(:ids, workflow: kid, max_items: 1, input:) }].each do |step|
        retried = proc do
          retry_on Smith::ChildRunsFailed, attempts: 2
          instance_exec(&step)
        end
        expect { declare.call(retried) }.to raise_error(Smith::WorkflowError, /does not take retry_on/)
      end
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
       [entry(0), entry(1).merge(extra: 1)], [entry(0), entry(1).merge(state: 1)],
       [entry(0), entry(1).merge(error: "x" * 257)], "not a list"].each do |payload|
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

    it "launches under a token of its own, from items given a copy of the context, and not past the deadline" do
      Smith.config.run_launcher = recording_launcher
      kid = child
      step_keys = []
      klass = with_stubbed_class("SpecSpawnOwnTokenWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        budget wall_clock: 60
        transition :notify, from: :idle, to: :done do
          spawn ->(ctx) { (ctx[:touched] = true) && ctx[:ids] }, workflow: kid, max_items: 3,
                                                                 input: lambda { |id, _ctx|
                                                                   step_keys << Smith::IdempotencyKey.current
                                                                   { id: }
                                                                 }
          on_failure :fail
        end
      end

      result = klass.new(context: { ids: [1] }).run_persisted!("spawn-token", adapter:)

      expect([result.state, result.context.key?(:touched)]).to eq([:done, false])
      expect(launches.sole[:await_token]).not_to eq(step_keys.sole)

      launches.clear
      late = klass.new(context: { ids: [1] })
      late.instance_variable_set(:@active_seconds, 120.0)
      expect(late.run_persisted!("spawn-late", adapter:).last_error).to be_a(Smith::DeadlineExceeded)
      expect(launches).to eq([])
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
        persist :doc, :secret, :ids, :results
        untrusted :doc, :secret
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
      klass.new(context: { ids: [1], doc: "outside", secret: "s" }).run_persisted!("untrusted-1", adapter:)

      run = launches.sole[:children].sole
      expect(run.untrusted_keys).to eq([:doc])
      built = run.build
      restored = kid.from_state(JSON.parse(JSON.generate(built.to_state)))
      expect(restored.send(:untrusted_context_keys)).to eq([:doc])
      ["doc", [1], [""], Array.new(1_001) { "k#{_1}" }].each do |keys|
        expect { kid.from_state(built.to_state.merge(inherited_untrusted_keys: keys)) }
          .to raise_error(Smith::SerializationError), keys.inspect[0, 40]
      end
      doubled = kid.from_state(JSON.parse(JSON.generate(built.to_state.merge(inherited_untrusted_keys: %w[doc doc]))))
      expect(doubled.to_state[:inherited_untrusted_keys]).to eq(%w[doc])
    end
  end

  describe "review fixes" do
    it "gives each child a key unique across the run's child-run steps, the token and ref together" do
      Smith.config.run_launcher = recording_launcher
      kid = child
      klass = with_stubbed_class("SpecTwoStepsWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :first, from: :idle, to: :half do
          map :ids, workflow: kid, max_items: 2, timeout: 60, input: ->(id, _ctx) { { id: } }, into: :a
          on_failure :fail
        end
        transition :second, from: :half, to: :done do
          call kid, input: ->(_ctx) { {} }, timeout: 60, into: :b
          on_failure :fail
        end
      end
      workflow = klass.new(context: { ids: [1] }).tap { _1.run_persisted!("two-1", adapter:) }
      klass.resume!("two-1", event: :children, token: workflow.awaiting.token, payload: [entry(0)], adapter:)
      klass.restore("two-1", adapter:).run_persisted!("two-1", adapter:)

      keys = launches.flat_map { |launch| launch[:children].map(&:key) }
      expect(launches.size).to eq(2)
      expect(keys.uniq.size).to eq(2)
      expect(keys.first).to eq(Smith::ChildRun.key_for(launches.first[:await_token], 0))
    end

    it "runs a spawn taken as a failure route" do
      Smith.config.run_launcher = recording_launcher
      kid = child
      klass = with_stubbed_class("SpecSpawnRouteWorkflow", workflow_class) do
        initial_state :idle
        transition :work, from: :idle, to: :done do
          compute { |_step| raise "boom" }
          on_failure :alert
        end
        transition :alert, from: :idle, to: :alerted do
          spawn ->(_ctx) { [1] }, workflow: kid, max_items: 1, input: ->(id, _ctx) { { id: } }
        end
      end

      klass.new.run_persisted!("spawn-route", adapter:)

      expect(launches.size).to eq(1)
    end

    it "checks results against the children it launched, and refuses an items key that is not persisted" do
      Smith.config.run_launcher = recording_launcher
      kid = child
      listed = Class.new(Smith::Context) { persist :results }
      klass = with_stubbed_class("SpecUnpersistedItemsWorkflow", workflow_class) do
        context_manager listed
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          map :ids, workflow: kid, max_items: 2, timeout: 60, input: ->(id, _ctx) { { id: } }, into: :results
          on_failure :fail
        end
      end
      expect(klass.new(context: { ids: [1] }).run_persisted!("np-1", adapter:).last_error.message)
        .to match(/items key :ids must be persisted/)

      sourced = parent("SpecCountedWorkflow", child)
      workflow = sourced.new(context: { ids: %w[a b] }).tap { _1.run_persisted!("counted-1", adapter:) }
      expect(workflow.awaiting.children).to eq(2)
      stored = JSON.parse(adapter.fetch("counted-1"))
      stored["context"]["ids"] = %w[a b c]
      adapter.store("counted-1", JSON.generate(stored))
      expect(sourced.resume!("counted-1", event: :children, token: workflow.awaiting.token,
                                          payload: [entry(0), entry(1)], adapter:)).to eq(:resumed)
    end

    it "refuses a stored wait whose children count is not a launch count, or an await's that has one" do
      Smith.config.run_launcher = recording_launcher
      klass = parent("SpecStoredCountWorkflow", child)
      mapped = klass.new(context: { ids: %w[a b] }).tap { _1.run_persisted!("count-1", adapter:) }.to_state
      expect(klass.from_state(mapped).awaiting.children).to eq(2)
      ["2", -1, 10_001, nil].each do |count|
        bad = mapped.merge(awaiting: mapped[:awaiting].merge("children" => count))
        expect { klass.from_state(bad) }.to raise_error(Smith::SerializationError), count.inspect
      end

      awaiting = with_stubbed_class("SpecStoredAwaitWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :wait, from: :idle, to: :done do
          await :reply, into: :reply, timeout: 60
          on_failure :fail
        end
      end
      waited = awaiting.new.tap { _1.run_persisted!("count-2", adapter:) }.to_state
      expect(awaiting.from_state(waited)).to be_waiting
      expect { awaiting.from_state(waited.merge(awaiting: waited[:awaiting].merge("children" => 1))) }
        .to raise_error(Smith::SerializationError)
    end

    it "takes no launcher's return value as results unless it runs children itself" do
      returning = Class.new { define_method(:launch) { |children:, **| children.map(&:ref) } }
      Smith.config.run_launcher = returning.new
      klass = parent("SpecReturningLauncherWorkflow", child)

      workflow = klass.new(context: { ids: %w[a] }).tap { _1.run_persisted!("ret-1", adapter:) }

      expect(workflow).to be_waiting
    end

    it "lets a strict run that crashed mid-launch launch again" do
      crash = Class.new(Exception) # rubocop:disable Lint/InheritException
      calls = 0
      flaky = Class.new { define_method(:launch) { |**| (calls += 1) == 1 ? raise(crash) : nil } }
      Smith.config.run_launcher = flaky.new
      kid = child
      klass = with_stubbed_class("SpecStrictMapWorkflow", workflow_class) do
        idempotency_mode :strict
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          map :ids, workflow: kid, max_items: 2, timeout: 60, input: ->(id, _ctx) { { id: } }, into: :results
          on_failure :fail
        end
      end

      expect { klass.new(context: { ids: [1] }).run_persisted!("strict-1", adapter:) }.to raise_error(crash)
      restored = klass.restore("strict-1", adapter:)
      restored.run_persisted!("strict-1", adapter:)

      expect(restored).to be_waiting
      expect(calls).to eq(2)
    end

    it "needs on_failure when a failed child fails the step" do
      kid = child
      klass = workflow_class
      expect do
        Class.new(klass) do
          transition :fan, from: :a, to: :b do
            map :ids, workflow: kid, max_items: 1, timeout: 60, input: ->(*) { {} }, into: :r
            on_timeout :late
          end
        end
      end.to raise_error(Smith::WorkflowError, /must declare on_failure/)
      expect do
        Class.new(klass) do
          transition :fan, from: :a, to: :b do
            map :ids, workflow: kid, max_items: 1, timeout: 60, input: ->(*) { {} }, into: :r, on_item_failure: :collect
            on_timeout :late
          end
          transition :late, from: :a, to: :c
        end
      end.not_to raise_error
    end

    it "bounds results after dropping the outputs a map does not collect, and completes at once with no items" do
      Smith.config.run_launcher = recording_launcher
      klass = parent("SpecLargeMapWorkflow", child, collect: :none, max_items: 10_000)
      workflow = klass.new(context: { ids: Array.new(10_000) { _1 } }).tap { _1.run_persisted!("large-1", adapter:) }
      results = Array.new(10_000) { entry(_1, "succeeded", "x" * 450) }

      expect(workflow.resume!(event: :children, token: workflow.awaiting.token, payload: results)).to eq(:resumed)
      expect(workflow.to_state[:context][:results]).to eq(succeeded: 10_000, failed: 0)

      launches.clear
      empty = klass.new(context: { ids: [] })
      empty.run_persisted!("empty-1", adapter:)
      expect([empty.waiting?, empty.state, launches]).to eq([false, :done, []])
      expect(empty.to_state[:context][:results]).to eq(succeeded: 0, failed: 0)
    end

    it "keeps an await of an event named children to the wait bound" do
      klass = with_stubbed_class("SpecAwaitChildrenWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :wait, from: :idle, to: :done do
          await :children, into: :reply, timeout: 60
          on_failure :fail
        end
      end
      workflow = klass.new.tap { _1.run_persisted!("aw-1", adapter:) }

      expect { workflow.resume!(event: :children, token: workflow.awaiting.token, payload: "x" * (2 * 1024 * 1024)) }
        .to raise_error(Smith::WorkflowError, /wait payload/)
    end

    it "refuses child untrusted keys that are not context key names" do
      kid = child
      run = Smith::ChildRun.new(ref: 0, key: "k", workflow: kid, input: { doc: "x" }, untrusted_keys: ["doc", :doc])
      expect(run.build.send(:untrusted_context_keys)).to eq([:doc])
      expect(run.build.to_state[:inherited_untrusted_keys]).to eq(%w[doc])
      longest = Smith::ChildRun.new(ref: 0, key: "k", workflow: kid, input: {}, untrusted_keys: ["k" * 256])
      expect(longest.build.to_state[:inherited_untrusted_keys]).to eq(["k" * 256])

      [[1], [""], ["k" * 257], "doc", Array.new(1_001) { "k#{_1}" }].each do |keys|
        bad = Smith::ChildRun.new(ref: 0, key: "k", workflow: kid, input: {}, untrusted_keys: keys)
        expect { bad.build }.to raise_error(Smith::WorkflowError), keys.inspect[0, 30]
      end
    end

    it "runs inline children apart from the parent: its deadline, but not its tools or attribution" do
      Smith.config.run_launcher = Smith::Launchers::Inline.new
      seen = []
      tooled = child("SpecInlineTooled") do
        transition :use, from: :done, to: :used do
          compute do |_step|
            seen << [Smith::Attribution.current.execution_key, Smith::Tool.current_deadline]
            Smith::Tool.current_tool_execution_tracker.mark_started!
            raise NameError, "oops"
          end
        end
      end
      klass = with_stubbed_class("SpecInlineApartWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        budget wall_clock: 600
        transition :fan, from: :idle, to: :done do
          map :ids, workflow: tooled, max_items: 1, timeout: 60, input: ->(id, _ctx) { { id: } }, into: :results
          on_failure :fail
        end
      end

      result = klass.new(context: { ids: %w[a] }).run_persisted!("inline-apart", adapter:)

      expect(result.last_error).to be_a(Smith::ChildRunsFailed)
      expect(seen.sole.first).to be_nil
      expect(seen.sole.last).to be_within(5).of(Time.now.utc + 600)
    end

    it "reports an inline child left waiting, or one that raised, as failed with its error" do
      Smith.config.run_launcher = Smith::Launchers::Inline.new
      waiting = child("SpecInlineWaiting") do
        state :failed
        transition :hold, from: :done, to: :held do
          await :reply, into: :reply, timeout: 60
          on_failure :fail
        end
      end
      raising = child("SpecInlineRaising") { define_method(:run!) { raise KeyError, "missing" } }

      { waiting => "waiting", raising => "KeyError" }.each_with_index do |(kid, error), index|
        klass = parent("SpecInlineFailed#{index}", kid, on_item_failure: :collect, collect: :states)
        result = klass.new(context: { ids: %w[a] }).run!
        expect(result.context[:results].sole).to include(status: "failed", error:), kid.name
      end
    end

    it "reports a child that handled a failure through on_failure as failed" do
      handled = Smith::Workflow::RunResult.new(state: :recovered, output: nil, steps: [{ error: RuntimeError.new }])

      expect(Smith::ChildRun.result(ref: 0, run_result: handled)[:status]).to eq("failed")
    end

    it "flags a nested in-process child that launches, and lets a durable map recurse" do
      Smith.config.run_launcher = recording_launcher
      inner = with_stubbed_class("SpecNestedLauncher", workflow_class) do
        initial_state :idle
        transition :go, from: :idle, to: :done do
          spawn ->(_ctx) { [] }, workflow: Class.new(Smith::Workflow) { initial_state :idle }, max_items: 1,
                                 input: ->(*) { {} }
        end
      end
      outer = with_stubbed_class("SpecNestingOuter", workflow_class) do
        initial_state :idle
        transition(:nest, from: :idle, to: :done) { workflow inner }
      end
      expect(outer.graph.runtime_readiness.diagnostics.map(&:code)).to include(:nested_workflow_waits)

      Smith.config.run_launcher = Smith::Launchers::Inline.new
      expect(outer.graph.runtime_readiness.diagnostics.map(&:code)).not_to include(:nested_workflow_waits)

      recursive = with_stubbed_class("SpecRecursiveMap", workflow_class) do
        itself = self
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          map ->(_ctx) { [] }, workflow: itself, max_items: 1, timeout: 60, input: ->(*) { {} }, into: :r
          on_failure :fail
        end
      end
      expect(recursive.graph.runtime_readiness.diagnostics.map(&:code)).not_to include(:nested_workflow_cycle)
    end

    it "refuses ChildRunsFailed details that do not add up" do
      good = { "transition" => "fan", "failed_refs" => [0, 1], "failed" => 2, "total" => 3 }

      expect(Smith::ChildRunsFailed.from_details(good).failed).to eq(2)
      [good.merge("failed_refs" => [0, 0]), good.merge("failed_refs" => [0, 3]), good.merge("failed_refs" => [0]),
       good.merge("failed_refs" => [-1, 0]),
       good.merge("failed_refs" => (0...20).to_a, "failed" => 25, "total" => 22),
       good.merge("total" => 3.0)].each do |bad|
        expect { Smith::ChildRunsFailed.from_details(bad) }.to raise_error(ArgumentError), bad.inspect
      end
    end

    it "needs results from a launcher that runs children itself, and counts them against what it launched" do
      silent = Class.new do
        def inline? = true
        def launch(**) = nil
      end
      Smith.config.run_launcher = silent.new
      expect(parent("SpecSilentInlineWorkflow", child).new(context: { ids: %w[a] }).run!.last_error.message)
        .to match(/must return the children's results/)
      queued = Class.new do
        def inline? = false
        def launch(**) = nil
      end
      Smith.config.run_launcher = queued.new
      expect(parent("SpecQueuedWorkflow", child).new(context: { ids: %w[a] }).run!.last_error.message)
        .to match(/needs a persisted run/)

      Smith.config.run_launcher = Smith::Launchers::Inline.new
      kid = child
      calls = 0
      growing = with_stubbed_class("SpecGrowingItemsWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          map ->(_ctx) { Array.new(calls += 1) { _1 } }, workflow: kid, max_items: 5, timeout: 60,
                                                         input: ->(id, _ctx) { { id: } }, into: :results
          on_failure :fail
        end
      end
      result = growing.new.run!
      expect([result.state, result.context[:results].length, calls]).to eq([:done, 1, 1])
    end

    it "bounds inline results after dropping the outputs a map does not collect" do
      Smith.config.run_launcher = Smith::Launchers::Inline.new
      answering(with_stubbed_class("SpecBigAnswerAgent", Smith::Agent) { register_as :spec_big_answer }, "x" * 600_000)
      big = with_stubbed_class("SpecBigOutputChild", workflow_class) do
        initial_state :idle
        transition(:work, from: :idle, to: :done) { execute :spec_big_answer }
      end
      ids = Array.new(8) { _1 }

      outputs = parent("SpecBigOutputsWorkflow", big, max_items: 8).new(context: { ids: }).run!
      states = parent("SpecBigStatesWorkflow", big, max_items: 8, collect: :states).new(context: { ids: }).run!

      expect([outputs.state, outputs.last_error&.message]).to match([:failed, /child run results/])
      expect([states.state, states.context[:results].length]).to eq([:done, 8])
    ensure
      Smith::Agent::Registry.delete(:spec_big_answer)
    end

    it "bounds a step's child inputs together as it builds them, before anything launches" do
      Smith.config.run_launcher = recording_launcher
      built = 0
      kid = child
      klass = with_stubbed_class("SpecHeavyInputsWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          spawn :ids, workflow: kid, max_items: 30, input: ->(id, _ctx) { (built += 1) && { id:, blob: "x" * 900_000 } }
          on_failure :fail
        end
      end

      result = klass.new(context: { ids: Array.new(30) { _1 } }).run_persisted!("heavy-1", adapter:)

      expect(result.last_error.message).to match(/inputs come to more than 16777216 bytes/)
      expect([built, launches]).to eq([19, []])
    end

    it "refuses to prepare a map, call or spawn as a split step" do
      Smith.config.run_launcher = recording_launcher
      kid = child
      klass = with_stubbed_class("SpecSplitSpawnWorkflow", workflow_class) do
        definition_digest Digest::SHA256.hexdigest("spec-split-spawn")
        idempotency_mode :strict
        initial_state :idle
        transition :fan, from: :idle, to: :done do
          spawn :ids, workflow: kid, max_items: 2, input: ->(id, _ctx) { { id: } }
        end
      end

      expect { klass.new(context: { ids: [1] }).prepare_persisted_step!("split-spawn", adapter:) }
        .to raise_error(Smith::WorkflowError, /does not run steps that wait or launch runs/)
    end

    it "warns, rather than refuses, when a child run's agent reads a key its parent marks untrusted" do
      Smith.config.run_launcher = recording_launcher
      with_stubbed_class("SpecChildReaderAgent", Smith::Agent) do
        register_as :spec_child_reader
        model "gpt-5-mini"
        inputs :doc
      end
      reader = with_stubbed_class("SpecReadingChild", workflow_class) do
        initial_state :idle
        transition(:read, from: :idle, to: :done) { execute :spec_child_reader }
      end
      manager = Class.new(Smith::Context) do
        persist :doc, :ids, :results
        untrusted :doc
      end
      mapping = with_stubbed_class("SpecUntrustedReadinessMap", workflow_class) do
        context_manager manager
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          map :ids, workflow: reader, max_items: 2, timeout: 60, input: ->(id, _ctx) { { id: } }, into: :results
          on_failure :fail
        end
      end
      middle = with_stubbed_class("SpecUntrustedReadinessMiddle", workflow_class) do
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          map :ids, workflow: reader, max_items: 2, timeout: 60, input: ->(id, _ctx) { { id: } }, into: :results
          on_failure :fail
        end
      end
      nesting = with_stubbed_class("SpecUntrustedReadinessNest", workflow_class) do
        context_manager manager
        initial_state :idle
        transition(:delegate, from: :idle, to: :done) { workflow middle }
      end

      found = mapping.graph.runtime_readiness.diagnostics.select { _1.code == :nested_untrusted_agent_input }
      expect(found.map { [_1.severity, _1.transition] }).to eq([%i[warning fan]])
      expect(found.sole.message).to include("starts runs of SpecReadingChild", "refused if input: passes it")
      nested = nesting.graph.runtime_readiness.diagnostics.select { _1.code == :nested_untrusted_agent_input }
      expect(nested.map { [_1.severity, _1.transition, _1.target] })
        .to eq([[:warning, :delegate, "SpecUntrustedReadinessMiddle"]])
    ensure
      Smith::Agent::Registry.delete(:spec_child_reader)
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
