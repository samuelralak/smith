# frozen_string_literal: true

require "json"
require "open3"

# The key of every child a `call`, `map` or `spawn` step launches: no other
# child of its run shares it, wherever the step runs (at the run's root, in
# an in-process nested workflow, in a fan-out item, nested inside those),
# so a launcher idempotent on `child.key`, as docs/PERSISTENCE.md asks,
# launches every child. A child launched at the run's root keeps the key
# 0.16.0 gave it, so a host's runs in flight still find their children.
RSpec.describe "Smith::ChildRun keys" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  # Each child a launcher was handed: its key, ref and launching position.
  let(:handed) { [] }
  # The topic of each child that ran.
  let(:ran) { [] }
  let(:known_namespace) { "11111111-1111-4111-8111-111111111111" }

  around do |example|
    previous = Smith.config.run_launcher
    example.run
  ensure
    Smith.config.run_launcher = previous
  end

  def noting(children)
    where = Smith::IdempotencyKey.__send__(:current_scope)&.path&.map { _1.join(" ") }&.join(" / ")
    children.each { handed << { key: _1.key, ref: _1.ref, at: where } }
  end

  # A host's own launcher that runs children in process, idempotent on
  # `child.key`: it keeps one result a key and returns it when the key
  # comes again, as a host that keeps a run a key would.
  def host_inline
    spec = self
    kept = {}
    Class.new do
      define_method(:inline?) { true }
      define_method(:launch) do |children:, **|
        spec.noting(children)
        children.map { spec.run_once(kept, _1) }
      end
    end.new
  end

  # Runs the child, unless one of its key ran: then that one's result.
  def run_once(kept, child)
    kept[child.key] ||= Smith::ChildRun.result(ref: child.ref, run_result: child.build.run!)
    kept[child.key].merge(ref: child.ref)
  end

  def smith_inline
    spec = self
    Class.new(Smith::Launchers::Inline) do
      define_method(:launch) do |children:, parent_key:, await_token:|
        spec.noting(children)
        super(children:, parent_key:, await_token:)
      end
    end.new
  end

  # A host launcher that queues: it records each launch and returns nothing.
  def host_queue
    spec = self
    launches = []
    Class.new do
      define_method(:launches) { launches }
      define_method(:launch) do |**call|
        spec.noting(call[:children])
        launches << call
        nil
      end
    end.new
  end

  def launchers
    { "a host's own inline launcher, idempotent on the key" => host_inline, "Smith::Launchers::Inline" => smith_inline }
  end

  def collisions
    shared = handed.group_by { _1[:key] }.select { |_key, group| group.length > 1 }
    shared.to_h { |key, group| [key[0, 12], group.map { "#{_1[:at]} ##{_1[:ref]}" }] }
  end

  def leaf
    noted = ran
    with_stubbed_class("SpecKeyLeaf", workflow_class) do
      initial_state :idle
      transition(:look, from: :idle, to: :done) { compute { |step| (noted << step.context[:topic]) && "looked" } }
    end
  end

  # Its first three steps launch children of the same content: a call, a
  # map of two and a spawn.
  def launching(name, child, to: :done)
    topic = ->(item, _context) { { topic: item } }
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      transition :ask, from: :idle, to: :asked do
        call child, input: ->(_context) { { topic: "same" } }, timeout: 60, into: :one
        on_failure :fail
      end
      transition :fan, from: :asked, to: :fanned do
        map ->(_context) { %w[same same] }, workflow: child, max_items: 2, timeout: 60, input: topic, into: :two
        on_failure :fail
      end
      transition :notify, from: :fanned, to: to do
        spawn ->(_context) { %w[same] }, workflow: child, max_items: 1, input: topic
      end
    end
  end

  def nest(name, inner, over: nil)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      transition :in, from: :idle, to: :done do
        over ? workflow(inner, over:, item_to: :room, concurrency: 1, output_to: :rooms) : workflow(inner)
      end
    end
  end

  # The run's own steps launch, then the same workflow's steps launch in
  # every place an in-process workflow runs: nested (twice), each of two
  # items, nested in a nested one, nested in each of two items, and in
  # each of two items of a nested one. Each `middle` launches what the
  # run's first three steps do, under the same step numbers and names.
  def everywhere(name)
    child = leaf
    places = in_places(name, launching("#{name}Middle", child))
    launching(name, child, to: :launched).tap { _1.class_exec(&places) }
  end

  def in_places(name, middle)
    over = ->(_context) { [1, 1] }
    deep = nest("#{name}Deep", middle)
    nest_items = nest("#{name}NestItems", middle, over:)
    items = { over:, item_to: :room, concurrency: 1 }
    proc do
      transition(:one, from: :launched, to: :one_done) { workflow middle }
      transition(:two, from: :one_done, to: :two_done) { workflow middle }
      transition(:rooms, from: :two_done, to: :roomed) { workflow middle, **items, output_to: :rooms }
      transition(:deep, from: :roomed, to: :deepened) { workflow deep }
      transition(:item_nest, from: :deepened, to: :item_nested) { workflow deep, **items, output_to: :item_nest }
      transition(:nest_items, from: :item_nested, to: :done) { workflow nest_items }
    end
  end

  # 4 children at the root, and 4 in each of the 9 places `middle` runs.
  let(:children_everywhere) { 4 + (4 * 9) }

  def known(klass)
    state = klass.new(context: {}).to_state.merge(execution_namespace: known_namespace)
    klass.from_state(JSON.parse(JSON.generate(state)))
  end

  describe "no two children of one run share a key" do
    it "under any in-process launcher, wherever the step runs, so one idempotent on the key runs every child" do
      launchers.each do |name, launcher|
        handed.clear
        ran.clear
        Smith.config.run_launcher = launcher
        result = everywhere("SpecKeysEverywhere").new(context: {}).run!

        expect([name, result.state, result.last_error&.message]).to eq([name, :done, nil])
        expect(handed.length).to eq(children_everywhere)
        expect(collisions).to eq({}), "#{name}: children sharing a key: #{collisions}"
        expect(ran.length).to eq(children_everywhere), "#{name} ran #{ran.length} of #{children_everywhere} children"
      end
    end

    it "nor do two runs, so one launcher idempotent on the key serves both" do
      Smith.config.run_launcher = host_inline
      klass = everywhere("SpecKeysTwoRuns")
      2.times { expect(klass.new(context: {}).run!.state).to eq(:done) }

      expect(handed.length).to eq(2 * children_everywhere)
      expect(collisions).to eq({})
      expect(ran.length).to eq(2 * children_everywhere)
    end

    # The launch is only reachable at the root with such a launcher, so
    # its keys there are all a host sees.
    it "and a host launcher that queues is handed only the run's root children: a nested one's step is refused" do
      child = leaf
      middle = launching("SpecKeysQueuedMiddle", child)
      [nest("SpecKeysQueuedNest", middle), nest("SpecKeysQueuedItems", middle, over: ->(_context) { [1, 2] })]
        .each_with_index do |klass, index|
          Smith.config.run_launcher = host_queue
          expect { klass.new(context: {}).run_persisted!("queued-#{index}", adapter:) }
            .to raise_error(Smith::WorkflowError, /call starts runs of their own, so it needs a persisted run/)
        end

      expect([handed, ran]).to eq([[], []])
    end
  end

  describe "the same child keeps its key" do
    it "on every launch from one payload, and a step around it tried again launches it under the same key" do
      flaky = Class.new(StandardError)
      tries = 0
      child = leaf
      middle = with_stubbed_class("SpecKeysRetried", workflow_class) do
        initial_state :idle
        state :failed
        transition :ask, from: :idle, to: :asked do
          call child, input: ->(_context) { { topic: "same" } }, timeout: 60, into: :one
          on_failure :fail
        end
        transition(:check, from: :asked, to: :done) { compute { |_step| (tries += 1) == 1 ? raise(flaky) : "ok" } }
      end
      retried = with_stubbed_class("SpecKeysRetry", workflow_class) do
        initial_state :idle
        state :failed
        transition :nest, from: :idle, to: :done do
          workflow middle
          retry_on flaky, attempts: 2
          on_failure :fail
        end
      end
      Smith.config.run_launcher = host_inline
      expect(retried.new(context: {}).run!.state).to eq(:done)
      expect([handed.map { _1[:key] }.uniq.length, handed.length, ran]).to eq([1, 2, ["same"]])

      handed.clear
      Smith.config.run_launcher = smith_inline
      klass = everywhere("SpecKeysPayload")
      payload = JSON.generate(klass.new(context: {}).to_state)
      launched = Array.new(2) do
        handed.clear
        expect(klass.from_state(JSON.parse(payload)).run!.state).to eq(:done)
        handed.map { _1[:key] }
      end
      expect(launched.first.length).to eq(children_everywhere)
      expect(launched.last).to eq(launched.first)
    end

    # Fresh processes, from a payload with a known namespace: the keys are
    # the same in each, and pinned, so a restored run in any process (or a
    # later Smith) finds the children its host kept.
    it "in another process, and as pinned: a nested workflow's child and each item's" do
      script = <<~RUBY
        require "json"
        require "smith"

        KEYS = []
        class Recording < Smith::Launchers::Inline
          def launch(children:, parent_key:, await_token:)
            KEYS.concat(children.map(&:key))
            super
          end
        end
        Smith.config.run_launcher = Recording.new
        class Leaf < Smith::Workflow
          initial_state :idle
          transition(:look, from: :idle, to: :done) { compute { |_step| "looked" } }
        end
        class Middle < Smith::Workflow
          initial_state :idle
          state :failed
          transition :ask, from: :idle, to: :done do
            call Leaf, input: ->(_context) { {} }, timeout: 60, into: :one
            on_failure :fail
          end
        end
        class Parent < Smith::Workflow
          initial_state :idle
          state :failed
          transition :ask, from: :idle, to: :asked do
            call Leaf, input: ->(_context) { {} }, timeout: 60, into: :one
            on_failure :fail
          end
          transition(:nest, from: :asked, to: :nested) { workflow Middle }
          transition :rooms, from: :nested, to: :done do
            workflow Middle, over: ->(_context) { [1, 1] }, item_to: :room, concurrency: 1, output_to: :rooms
          end
        end
        state = Parent.new(context: {}).to_state.merge(execution_namespace: ARGV.first)
        Parent.from_state(JSON.parse(JSON.generate(state))).run!
        puts JSON.generate(KEYS)
      RUBY
      lib = File.expand_path("../../../lib", __dir__)
      runs = Array.new(2) { Open3.capture2e(RbConfig.ruby, "-I#{lib}", "-e", script, known_namespace) }

      expect(runs.map { _2.success? }).to eq([true, true]), runs.first.first
      keys = runs.map { JSON.parse(_1.first.lines.last.to_s) }
      expect(keys.last).to eq(keys.first)
      expect(keys.first.uniq.length).to eq(4), "keys shared: #{keys.first}"
      # The run's own call (0.16.0's key), the nested workflow's, and each
      # item's.
      expect(keys.first).to eq(%w[5879b03f4c08d685290b54e71e9136471a941b301a4cc43e0b43dd6a56b81d4d
                                  41d9b966bddbc02eb269688ebbf4d1de74c8a3c3063aefaedfda9d9ff908165a
                                  0e1dd866892fbcbedda654868bb1c04b221cbd581967aa5ba7b0fa8de7fdfdd2
                                  7ff9ede73a5b5c5601b27371fd57b02511c4961b5924036ebe34b2abfeacf8ff])
    end

    it "launched at the run's root, as 0.16.0 gave it, under every launcher kind" do
      queue = host_queue
      Smith.config.run_launcher = queue
      klass = launching("SpecKeysRoot", leaf)
      entry = ->(ref) { { ref:, status: "succeeded", state: "done", output: "out" } }
      known(klass).run_persisted!("root", adapter:)
      [[0, [entry.call(0)]], [1, [entry.call(0), entry.call(1)]]].each do |launch, payload|
        klass.resume!("root", event: :children, token: queue.launches[launch][:await_token], payload:, adapter:)
        klass.restore("root", adapter:).run_persisted!("root", adapter:)
      end

      # Its call, its map of two of the same content and its spawn, as
      # 0.16.0 (and every Smith since) gave them.
      pinned = %w[5879b03f4c08d685290b54e71e9136471a941b301a4cc43e0b43dd6a56b81d4d
                  59854d0cca289c879fb09711a024caecea3b1412bd0ccf1638a3f49c2d37f8cb
                  450c383ea040cc4555521fa6dacc05c78a17f77e0aef19922af4e1e6da562b17
                  8dab371fae279da02786fedf3a84fa496a07417a400596f65397320732a83fd3]
      expect(klass.restore("root", adapter:).state).to eq(:done)
      expect(handed.map { _1[:key] }).to eq(pinned)
      tokens = %w[8250ffe3544ac192472d4865dd2d37b201e715c1b4c6102b8184453df4eca65e
                  91d5d5214c331f1c58b059ea19161f5f4a5ea59a7f9aad64831dc8e87ad82440
                  c509b60acdc57951034cc1d0d40ee52a454c8022ba32b71b1717553fd4751a62]
      expect(queue.launches.map { _1[:await_token] }).to eq(tokens)
      launchers.each_value do |launcher|
        handed.clear
        Smith.config.run_launcher = launcher
        expect(known(klass).run!.state).to eq(:done)
        expect(handed.map { _1[:key] }).to eq(pinned)
      end
    end
  end
end
