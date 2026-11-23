# frozen_string_literal: true

require "digest"
require "json"
require "open3"

# Children a `call`, `map` or `spawn` step runs through
# Smith::Launchers::Inline, launched again when their parent, restored after
# its process died, runs the step again. A child launched again is the same
# child, named by its key: the calls the response memo kept replay (it
# sends, holds and charges what an uncut run does), its tools repeat their
# idempotency keys, and it owns what its earlier launch stored.
RSpec.describe "Smith::Launchers::Inline children launched again after a restore" do
  include_context "with a recording budget ledger"

  # The process dies once, right after the memo keeps its `die_after`th
  # whole call. Each fetch notes whether it found a record.
  let(:crash) { Class.new(Exception) } # rubocop:disable Lint/InheritException
  let(:memo_class) do
    Class.new do
      attr_accessor :crash, :die_after
      attr_reader :records, :found

      def initialize(records = {})
        @records = records
        @found = []
      end

      def fetch(key) = @records[key].tap { @found << !_1.nil? }

      def store(key, record)
        @records[key] = record
        dies = crash
        return unless dies && record["complete"] && @records.values.count { _1["complete"] } == die_after

        self.crash = nil
        raise dies
      end
    end
  end
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  # Each child run that finished, in order: its topic and its usage.
  let(:finished) { [] }
  # What each child sees of itself when it starts.
  let(:seen) { [] }
  let(:calls) do
    ["Brief the clinic.", "Look into the hours.", "Look into the address.", "Look into the address.",
     "Look into the parking.", "Wrap up."]
  end
  # The parent's five steps: the calls each makes and the children each
  # launches.
  let(:calls_by_step) { [1, 1, 2, 1, 1] }
  let(:children_by_step) { [0, 1, 2, 1, 0] }
  let(:namespace) { /\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/ }

  around do |example|
    memo = Smith.config.response_memo
    store = Smith.config.artifact_store
    example.run
  ensure
    Smith.config.response_memo = memo
    Smith.config.artifact_store = store
  end

  before do
    Smith.config.run_launcher = Smith::Launchers::Inline.new
    agent("SpecRelaunchAgent", register: :spec_relaunch_agent)
  end

  def asked(text) = ->(_context) { [{ role: :user, content: text }] }

  # Notes each run that finishes: its topic and usage.
  def noting
    done = finished
    Module.new do
      define_method(:run!) do
        super().tap { done << [to_state[:context][:topic], usage_entries.map { [_1.input_tokens, _1.output_tokens] }] }
      end
    end
  end

  # A child: one call on its topic, noted when it finishes.
  def kid(name, led)
    looking = ->(context) { [{ role: :user, content: "Look into the #{context[:topic]}." }] }
    note = noting
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger { |_scope| led }
      transition :look, from: :idle, to: :done do
        execute :spec_relaunch_agent, input: looking, output_to: :finding
        on_failure :fail
      end
      prepend note
    end
  end

  # Its own call, then a call child, a map over two children of the same
  # content and a spawn (`launching`), and its own call again.
  def parent(name, led, child)
    brief = asked("Brief the clinic.")
    klass = with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger { |_scope| led }
      transition :brief, from: :idle, to: :briefed do
        execute :spec_relaunch_agent, input: brief, output_to: :brief
        on_failure :fail
      end
    end
    finishing(launching(klass, child))
  end

  def launching(klass, child)
    topic = ->(item, _context) { { topic: item } }
    klass.class_exec do
      transition :delegate, from: :briefed, to: :delegated do
        call child, input: ->(_context) { { topic: "hours" } }, timeout: 60, into: :hours
        on_failure :fail
      end
      transition :fan, from: :delegated, to: :fanned do
        map ->(_context) { %w[address address] }, workflow: child, max_items: 2, timeout: 60, input: topic, into: :rooms
        on_failure :fail
      end
      transition :notify, from: :fanned, to: :notified do
        spawn ->(_context) { %w[parking] }, workflow: child, max_items: 1, input: topic
      end
    end
    klass
  end

  def finishing(klass)
    wrap = asked("Wrap up.")
    klass.class_exec do
      transition :wrap, from: :notified, to: :done do
        execute :spec_relaunch_agent, input: wrap, output_to: :wrap
        on_failure :fail
      end
    end
    klass
  end

  # A child that notes itself as it starts, and does nothing more.
  def leaf(name = "SpecRelaunchLeaf")
    noted = seen
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      transition(:look, from: :idle, to: :done) { compute { |_step| "looked" } }
      define_method(:run!) { (noted << self) && super() }
    end
  end

  def namespaces = seen.map { _1.to_state[:execution_namespace] }

  def said(request)
    content = request.body.fetch("messages").last.fetch("content")
    content.is_a?(String) ? content : content.map { _1["text"] }.join
  end

  # Answers each request by what it asks, so one sent again gets the same
  # reply.
  def answer_by_request
    server.answer do |request|
      said = said(request)
      { json: message("Noted: #{said}", tokens: said.start_with?("Look") ? [20, 4] : [30, 8]) }
    end
  end

  # What a run (persisted under `key`) sent, held and charged, its own
  # usage and its children's, and how it ended. `kept` are the children
  # that finished before a cut in steps the run does not take again.
  def story(run, key, led, from, kept = [])
    result = run.run_persisted!(key, adapter:)
    charged(led, from).merge(output: [result.state, result.last_error&.message],
                             context: run.class.restore(key, adapter:).to_state[:context], usage: usage_of(run),
                             children: kept + finished)
  end

  # The requests sent since `from`, and each hold and settlement with its
  # amount and how many keys they took.
  def charged(led, from)
    { sent: server.requests.drop(from).map { said(_1) }, ledger: led.calls.map { [_1.first, _1[2]] },
      hold_keys: led.keys.uniq.length }
  end

  def usage_of(run) = run.usage_entries.map { [_1.agent_name, _1.input_tokens, _1.output_tokens] }

  def uncut_story
    Smith.config.response_memo = memo_class.new
    led = ledger_class.new
    from = server.requests.length
    story(parent("SpecRelaunchUncutWorkflow", led, kid("SpecRelaunchUncutChild", led)).new(context: {}),
          "run-uncut", led, from).tap { finished.clear }
  end

  describe "a persisted run cut once the memo has kept a call" do
    {
      1 => "its own first call", 2 => "the call child's call", 3 => "the first map child's call",
      4 => "the second map child's call, of the same content", 5 => "the spawned child's call",
      6 => "its own last call"
    }.each do |die_after, kept|
      it "restored after #{kept} was kept, sends, holds and charges what an uncut run does and ends the same" do
        answer_by_request
        uncut = uncut_story
        expect(uncut[:sent]).to eq(calls)
        expect(uncut[:children].map(&:first)).to eq(%w[hours address address parking])

        memo = Smith.config.response_memo = memo_class.new
        memo.crash = crash
        memo.die_after = die_after
        led = ledger_class.new
        klass = parent("SpecRelaunchCut#{die_after}Workflow", led, kid("SpecRelaunchCut#{die_after}Child", led))
        from = server.requests.length
        expect { klass.new(context: {}).run_persisted!("run-cut", adapter:) }.to raise_error(crash)
        expect(server.requests.length - from).to eq(die_after)
        restored = klass.restore("run-cut", adapter:)
        steps = restored.to_state[:step_count]
        kept_children = finished.first(children_by_step.first(steps).sum)
        finished.clear
        found_before = memo.found.length

        expect(story(restored, "run-cut", led, from, kept_children)).to eq(uncut)
        replayable = die_after - calls_by_step.first(steps).sum
        expect(memo.found.drop(found_before).first(replayable)).to eq([true] * replayable)
        expect(memo.records.length).to eq(calls.length)
      end
    end
  end

  describe "a child's identity" do
    it "is its own: no two children share it, whatever their step, place, content or nesting, and it is a namespace" do
      grandchild = leaf
      noted = seen
      # A workflow whose one step calls the leaf; the branch, launched as a
      # child itself, notes itself too.
      middle, branch = %w[SpecRelaunchMiddle SpecRelaunchBranch].map do |name|
        with_stubbed_class(name, workflow_class) do
          initial_state :idle
          state :failed
          transition :ask, from: :idle, to: :done do
            call grandchild, input: ->(_context) { {} }, timeout: 60, into: :found
            on_failure :fail
          end
          define_method(:run!) { (noted << self) && super() } if name.end_with?("Branch")
        end
      end
      klass = with_stubbed_class("SpecRelaunchIdsWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :delegate, from: :idle, to: :delegated do
          call grandchild, input: ->(_context) { { topic: "same" } }, timeout: 60, into: :one
          on_failure :fail
        end
        transition :fan, from: :delegated, to: :fanned do
          map ->(_context) { %w[same same] }, workflow: grandchild, max_items: 2, timeout: 60, into: :two,
                                              input: ->(topic, _context) { { topic: } }
          on_failure :fail
        end
        transition :notify, from: :fanned, to: :notified do
          spawn ->(_context) { %w[same] }, workflow: grandchild, max_items: 1, input: ->(topic, _context) { { topic: } }
        end
        transition(:nest, from: :notified, to: :nested) { workflow middle }
        transition :rooms, from: :nested, to: :roomed do
          workflow middle, over: ->(_context) { [1, 1] }, item_to: :room, concurrency: 1, output_to: :rooms
        end
        transition :deeper, from: :roomed, to: :done do
          call branch, input: ->(_context) { {} }, timeout: 60, into: :deep
          on_failure :fail
        end
      end
      payload = JSON.generate(klass.new(context: {}).to_state)

      runs = Array.new(2) do
        seen.clear
        expect(klass.from_state(JSON.parse(payload)).run!.state).to eq(:done)
        namespaces
      end
      restorable = seen.map { _1.class.from_state(JSON.parse(JSON.generate(_1.to_state))) }
                       .map { _1.to_state[:execution_namespace] }
      seen.clear
      klass.new(context: {}).run!

      expect(runs.first.length).to eq(9)
      expect(runs.first.uniq.length).to eq(9)
      expect(runs.first).to all(match(namespace))
      expect(runs.last).to eq(runs.first)
      expect(restorable).to eq(runs.first)
      expect(namespaces & runs.first).to eq([])
    end

    it "repeats its tools' idempotency keys when launched again, so an outside system sees one call" do
      runs = []
      used = []
      dies = crash
      stub_const("SpecRelaunchLookup", Class.new(Smith::Tool) do
        param :query, type: :string, required: true
        define_method(:perform) do |query:|
          runs << query
          used << idempotency_key(:lookup)
          raise dies if runs.length == 2

          { found: "#{query} opens at 8" }
        end
      end)
      agent("SpecRelaunchToolAgent", register: :spec_relaunch_tool_agent) { tools SpecRelaunchLookup }
      tooled = with_stubbed_class("SpecRelaunchTooled", workflow_class) do
        initial_state :idle
        state :failed
        transition :look, from: :idle, to: :done do
          execute :spec_relaunch_tool_agent, input: ->(_context) { [{ role: :user, content: "Find the hours." }] }
          on_failure :fail
        end
      end
      klass = with_stubbed_class("SpecRelaunchToolWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          map ->(_context) { %w[same same] }, workflow: tooled, max_items: 2, timeout: 60, input: ->(*) { {} },
                                              into: :found
          on_failure :fail
        end
      end
      server.answer do |request|
        answered = request.body.fetch("messages").last.fetch("content").to_s.include?("opens at 8")
        next { json: message("It opens at 8.", tokens: [30, 5]) } if answered

        { json: message(nil, content: tool_use("spec_relaunch_lookup", input: { "query" => "clinic" }),
                             stop: "tool_use", tokens: [10, 4]) }
      end
      Smith.config.response_memo = memo_class.new

      expect { klass.new(context: {}).run_persisted!("run-tools", adapter:) }.to raise_error(crash)
      done = klass.restore("run-tools", adapter:).run_persisted!("run-tools", adapter:)

      expect(done.state).to eq(:done)
      expect(used.length).to eq(3)
      expect(used.uniq.length).to eq(2)
      expect(used.last).to eq(used[1])
      expect(server.requests.length).to eq(4)
    end

    it "owns what its earlier launch stored: it reads, lists and deletes it as its own" do
      Smith.config.artifact_store = store = Smith::Artifacts::Memory.new
      refs = []
      held = []
      dies = crash
      keeper = with_stubbed_class("SpecRelaunchKeeper", workflow_class) do
        initial_state :idle
        transition :keep, from: :idle, to: :done do
          compute do |_step|
            artifacts = Smith.artifacts
            if refs.empty?
              refs << artifacts.store("first draft", content_type: "text/plain")
              raise dies
            end
            held.push(artifacts.fetch(refs.first), artifacts.expired(retention: 0))
            artifacts.delete(refs.first)
            "kept"
          end
        end
      end
      klass = with_stubbed_class("SpecRelaunchKeeperWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :delegate, from: :idle, to: :done do
          call keeper, input: ->(_context) { {} }, timeout: 60, into: :kept
          on_failure :fail
        end
      end

      expect { klass.new(context: {}).run_persisted!("run-keep", adapter:) }.to raise_error(crash)
      done = klass.restore("run-keep", adapter:).run_persisted!("run-keep", adapter:)

      expect(done.state).to eq(:done)
      expect(held).to eq(["first draft", refs])
      expect(store.fetch(refs.first.split(":").last)).to be_nil
    end

    # A step tried again launches the same child (its key, so its
    # namespace, its tools' keys and what it stored), and asks its calls
    # again, as it asks every call of the step: a retry never takes the
    # attempt before's answer.
    it "is the same child when a step around it is tried again, whose calls are asked again" do
      flaky = Class.new(StandardError)
      looker = kid("SpecRelaunchRetryChild", nil)
      noted = seen
      looker.prepend(Module.new { define_method(:run!) { (noted << self) && super() } })
      tries = 0
      middle = with_stubbed_class("SpecRelaunchFlaky", workflow_class) do
        initial_state :idle
        state :failed
        transition :ask, from: :idle, to: :asked do
          call looker, input: ->(_context) { { topic: "hours" } }, timeout: 60, into: :hours
          on_failure :fail
        end
        transition(:check, from: :asked, to: :done) { compute { |_step| (tries += 1) == 1 ? raise(flaky) : "ok" } }
      end
      klass = with_stubbed_class("SpecRelaunchRetry", workflow_class) do
        initial_state :idle
        state :failed
        transition :nest, from: :idle, to: :done do
          workflow middle
          retry_on flaky, attempts: 2
          on_failure :fail
        end
      end
      answer_by_request
      Smith.config.response_memo = memo = memo_class.new

      expect(klass.new(context: {}).run!.state).to eq(:done)
      expect([tries, server.requests.map { said(_1) }, memo.found])
        .to eq([2, ["Look into the hours."] * 2, [false, false]])
      expect([namespaces.length, namespaces.uniq.length]).to eq([2, 1])
    end

    it "is named by its key alone when launched outside any step, so one key names one child" do
      child = leaf
      run = ->(key) { Smith::ChildRun.new(ref: 0, key:, workflow: child, input: {}, untrusted_keys: []) }
      launcher = Smith::Launchers::Inline.new
      %w[a a b].each { launcher.launch(children: [run.call(_1 * 64)], parent_key: nil, await_token: "t") }

      expect(namespaces.first).to eq(namespaces[1])
      expect(namespaces.uniq.length).to eq(2)
      expect(namespaces).to all(match(namespace))
    end
  end

  # A nested workflow step tried again by retry_on: the nested workflow's
  # own call, an inline child's call, then a check that fails, retryably,
  # while the child's answer is bad. The child answers "bad" the first time
  # it is asked and "good" after.
  describe "a step around it tried again" do
    let(:flaky) { Class.new(StandardError) }

    def nested(name, check)
      child = kid("#{name}Child", nil)
      brief = asked("Brief the clinic.")
      checking = checker(check)
      with_stubbed_class(name, workflow_class) do
        initial_state :idle
        state :failed
        transition :own, from: :idle, to: :briefed do
          execute :spec_relaunch_agent, input: brief, output_to: :brief
          on_failure :fail
        end
        transition :ask, from: :briefed, to: :asked do
          call child, input: ->(_context) { { topic: "hours" } }, timeout: 60, into: :hours
          on_failure :fail
        end
        transition(:check, from: :asked, to: :done) { compute(&checking) }
      end
    end

    # A step that passes when `check` takes the child's answer, and fails
    # retryably when it does not.
    def checker(check)
      fails = flaky
      ->(step) { check.call(step.context[:hours]) ? "ok" : raise(fails, "the child's answer was bad") }
    end

    def retried(name, check, attempts: 3)
      middle = nested("#{name}Nested", check)
      fails = flaky
      with_stubbed_class(name, workflow_class) do
        initial_state :idle
        state :failed
        transition :nest, from: :idle, to: :done do
          workflow middle
          retry_on fails, attempts: attempts
          on_failure :fail
        end
      end
    end

    # Each request answered by how often it was asked: the child's first
    # answer is bad.
    def answering
      asked = Hash.new(0)
      server.answer do |request|
        text = said(request)
        asked[text] += 1
        reply = text.start_with?("Look") && asked[text] == 1 ? "bad" : "good #{asked[text]}"
        { json: message(reply, tokens: [20, 4]) }
      end
    end

    def good = ->(hours) { hours.to_s.include?("good") }

    it "asks the child's call again, as it asks the nested workflow's own" do
      tries = 0
      klass = retried("SpecRetryAgain", ->(_hours) { (tries += 1) > 1 }, attempts: 2)
      answering
      Smith.config.response_memo = memo = memo_class.new

      expect(klass.new(context: {}).run!.state).to eq(:done)
      expect(server.requests.map { said(_1) })
        .to eq(["Brief the clinic.", "Look into the hours.", "Brief the clinic.", "Look into the hours."])
      expect(memo.found).to eq([false] * 4)
    end

    it "asks every child of a map again, not only the first" do
      tries = 0
      child = kid("SpecRetryMapChild", nil)
      fails = flaky
      middle = with_stubbed_class("SpecRetryMapNested", workflow_class) do
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :fanned do
          map ->(_context) { %w[hours address] }, workflow: child, max_items: 2, timeout: 60,
                                                  input: ->(topic, _context) { { topic: } }, into: :found
          on_failure :fail
        end
        transition(:check, from: :fanned, to: :done) { compute { |_step| (tries += 1) > 1 ? "ok" : raise(fails) } }
      end
      klass = with_stubbed_class("SpecRetryMap", workflow_class) do
        initial_state :idle
        state :failed
        transition :nest, from: :idle, to: :done do
          workflow middle
          retry_on fails, attempts: 2
          on_failure :fail
        end
      end
      answering
      Smith.config.response_memo = memo = memo_class.new

      expect(klass.new(context: {}).run!.state).to eq(:done)
      expect(server.requests.map { said(_1) }).to eq(["Look into the hours.", "Look into the address."] * 2)
      expect(memo.found).to eq([false] * 4)
    end

    it "gets the child a new answer, so a run with a memo ends as one without does" do
      ends = [memo_class.new, nil].each_with_index.map do |memo, at|
        answering
        from = server.requests.length
        Smith.config.response_memo = memo
        result = retried("SpecRetryEnds#{at}", good).new(context: {}).run!
        [result.state, server.requests.drop(from).map { said(_1) }]
      end

      expect(ends.first).to eq([:done, ["Brief the clinic.", "Look into the hours."] * 2])
      expect(ends.last).to eq(ends.first)
    end

    # A restored run takes the step again from its first attempt, so every
    # call either attempt kept replays, in order, and the rest are sent.
    (1..4).each do |die_after|
      it "restored after #{die_after} of its 4 calls were kept, replays them through the retry and ends the same" do
        answering
        Smith.config.response_memo = memo_class.new
        uncut = retried("SpecRetryUncut#{die_after}", good)
        uncut_result = uncut.new(context: {}).run_persisted!("retry-uncut", adapter:)
        uncut_sent = server.requests.map { said(_1) }
        expect([uncut_result.state, uncut_sent]).to eq([:done, ["Brief the clinic.", "Look into the hours."] * 2])

        answering
        memo = Smith.config.response_memo = memo_class.new
        memo.crash = crash
        memo.die_after = die_after
        klass = retried("SpecRetryCut#{die_after}", good)
        from = server.requests.length
        expect { klass.new(context: {}).run_persisted!("retry-cut", adapter:) }.to raise_error(crash)
        found_before = memo.found.length
        result = klass.restore("retry-cut", adapter:).run_persisted!("retry-cut", adapter:)

        expect(server.requests.drop(from).map { said(_1) }).to eq(uncut_sent)
        expect([result.state, result.output]).to eq([uncut_result.state, uncut_result.output])
        expect(memo.found.drop(found_before).first(die_after)).to eq([true] * die_after)
        expect(memo.records.length).to eq(4)
      end
    end
  end

  describe "what does not change" do
    # A parent restored from a payload with a known namespace, so its
    # children's keys can be compared with what 0.16.0 gave.
    def known(klass)
      state = klass.new(context: {}).to_state.merge(execution_namespace: "11111111-1111-4111-8111-111111111111")
      klass.from_state(JSON.parse(JSON.generate(state)))
    end

    it "leaves a host launcher's children as they were: their keys and inputs, and a namespace of its own each build" do
      launches = []
      Smith.config.run_launcher = Class.new { define_method(:launch) { |**call| launches << call and nil } }.new
      child = leaf
      klass = with_stubbed_class("SpecRelaunchHostWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          map ->(_context) { %w[same same] }, workflow: child, max_items: 2, timeout: 60, into: :found,
                                              input: ->(topic, _context) { { topic: } }
          on_failure :fail
        end
      end
      known(klass).run_persisted!("run-host", adapter:)

      children = launches.sole[:children]
      expect(children.map(&:key)).to eq(%w[4aab2b7fab61e8297bd35785b87f6bab0a0800dfbfe72513efbaacd7edae66b5
                                           2efaf24c043df34dfe9729d38cef7fbb6ad61964bb4bd6b8f32550202fdc8ab0])
      expect(children.map(&:input)).to eq([{ topic: "same" }] * 2)
      built = Array.new(2) { children.first.build.to_state[:execution_namespace] }
      expect(built.uniq.length).to eq(2)
      expect(built).to all(match(namespace))
    end

    # From its definition, with Digest and JSON alone: the step's token,
    # the child's key (0.16.0's formula at the run's root), and the version
    # 4 UUID shape of the digest of that key under `inline_child`. Launched
    # an hour or a process later, the child must be the same run.
    it "names an inline child's namespace as its definition gives, from the child's key" do
      namespace = "11111111-1111-4111-8111-111111111111"
      child = leaf
      klass = with_stubbed_class("SpecRelaunchPinnedWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :ask, from: :idle, to: :done do
          call child, input: ->(_context) { {} }, timeout: 60, into: :found
          on_failure :fail
        end
      end
      state = klass.new(context: {}).to_state.merge(execution_namespace: namespace)
      klass.from_state(JSON.parse(JSON.generate(state))).run!
      version = "smith.idempotency.v1"
      token = Digest::SHA256.hexdigest(JSON.generate([version, namespace, [["step", 1, "ask"], ["wait"]],
                                                      %w[children children]]))
      key = Digest::SHA256.hexdigest("smith.child_run.v1:#{token}:0")
      hex = Digest::SHA256.hexdigest(JSON.generate([version, "inline_child", key]))
      variant = ((hex[16].to_i(16) & 0x3) | 0x8).to_s(16)

      expect(namespaces).to eq(["#{hex[0, 8]}-#{hex[8, 4]}-4#{hex[13, 3]}-#{variant}#{hex[17, 3]}-#{hex[20, 12]}"])
    end

    it "names an inline child by no key a step gets: none of its own, its children's or its token" do
      keys = []
      Smith.config.run_launcher = Class.new(Smith::Launchers::Inline) do
        define_method(:launch) do |children:, parent_key:, await_token:|
          scope = Smith::IdempotencyKey
          keys.push(await_token, scope.current, scope.current("child"))
          children.each { keys.push(_1.key, scope.current(_1.key), scope.current(_1.ref)) }
          super(children:, parent_key:, await_token:)
        end
      end.new
      child = leaf
      klass = with_stubbed_class("SpecRelaunchNoKeyWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          map ->(_context) { %w[a b] }, workflow: child, max_items: 2, timeout: 60, input: ->(*) { {} }, into: :found
          on_failure :fail
        end
      end
      klass.new(context: {}).run!

      ids = namespaces.map { _1.delete("-") }
      expect([ids.length, keys.length]).to eq([2, 9])
      expect(ids.product(keys).select { |id, key| key.start_with?(id[0, 12]) }).to eq([])
    end

    # In fresh processes, under Smith::Testing stubs: one dies once its
    # child's call is kept, another restores its payload and memo and
    # finishes.
    it "is the same in another process, which replays the child's call the first one kept" do
      script = <<~RUBY
        require "json"
        require "smith"
        require "smith/testing"

        RubyLLM.configure { _1.anthropic_api_key = "test" }
        Killed = Class.new(Exception)
        class Memo
          attr_reader :records, :found

          def initialize(records, cut: false)
            @records = records
            @found = []
            @cut = cut
          end

          def fetch(key) = @records[key].tap { @found << !_1.nil? }

          def store(key, record)
            @records[key] = record
            raise Killed if @cut
          end
        end
        class Looker < Smith::Agent
          register_as :looker
          model "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true
        end
        class Child < Smith::Workflow
          initial_state :idle
          seed_messages { |_context| [{ role: :user, content: "Look into the hours." }] }
          transition(:look, from: :idle, to: :done) { execute :looker }
        end
        class Parent < Smith::Workflow
          initial_state :idle
          state :failed
          transition :delegate, from: :idle, to: :done do
            call Child, input: ->(_context) { {} }, timeout: 60, into: :hours
            on_failure :fail
          end
        end
        Smith.config.run_launcher = Smith::Launchers::Inline.new
        adapter = Smith::PersistenceAdapters::Memory.new
        if ARGV.first == "cut"
          Smith.config.response_memo = Memo.new({}, cut: true)
          Smith::Testing.stub_agent(:looker, outputs: "kept")
          begin
            Parent.new(context: {}).run_persisted!("run", adapter:)
          rescue Killed
            puts JSON.generate(payload: adapter.fetch("run"), records: Smith.config.response_memo.records)
          end
        else
          kept = JSON.parse($stdin.read)
          adapter.store("run", kept.fetch("payload"))
          memo = Smith.config.response_memo = Memo.new(kept.fetch("records"))
          looker = Smith::Testing.stub_agent(:looker, outputs: "live")
          done = Parent.restore("run", adapter:).run_persisted!("run", adapter:)
          puts JSON.generate(state: done.state, hours: done.context[:hours], asked: looker.calls.length,
                             replayed: memo.found)
        end
      RUBY
      lib = File.expand_path("../../../lib", __dir__)
      cut, cut_status = Open3.capture2e(RbConfig.ruby, "-I#{lib}", "-e", script, "cut")
      restored, status = Open3.capture2e(RbConfig.ruby, "-I#{lib}", "-e", script, "restore",
                                         stdin_data: cut.lines.last.to_s)

      expect([cut_status.success?, status.success?]).to eq([true, true]), restored
      expect(JSON.parse(restored.lines.last.to_s))
        .to eq("state" => "done", "hours" => "kept", "asked" => 0, "replayed" => [true])
    end
  end
end
