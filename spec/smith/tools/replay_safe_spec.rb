# frozen_string_literal: true

require "json"
require "smith/testing/rspec"

# A tool that declares `capabilities { replay :safe }` may run again under the
# same keys. A step whose tools that ran are all replay-safe keeps output
# repair, the refusal and truncation follow-ups, the provider-failure
# fallback and its retries; an attempt it sets aside takes its tools'
# captures with it. A tool not declared safe keeps the step as before.
RSpec.describe "Smith::Tool replay :safe" do
  include_context "with a recording budget ledger"

  let(:runs) { [] }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:down) { { json: { type: "error", error: { type: "api_error", message: "down" } }, status: "500 Server Error" } }
  let(:score_schema) do
    Class.new do
      def to_json_schema
        { name: "review", schema: { type: "object", required: %w[score],
                                    properties: { score: { type: "integer", maximum: 5 } } } }
      end
    end
  end

  # A lookup that records each run and captures what it found.
  def lookup(name, safe:)
    ran = runs
    stub_const(name, Class.new(Smith::Tool) do
      description "Look up a place's opening hours."
      param :query, type: :string, required: true
      capabilities { replay :safe } if safe
      capture_result(strict: true) { |kwargs, result| { query: kwargs[:query], found: result[:found] } }
      define_method(:perform) { |query:| (ran << [name, query]) && { found: "#{query} opens at 8" } }
    end)
  end

  # A reply calling each of `tools` in one round.
  def calling(*tools, id:)
    content = tools.each_with_index.flat_map do |tool, index|
      tool_use(tool.new.name, id: tools.one? ? id : "#{id}_#{index}", input: { "query" => "clinic" })
    end
    { json: message(nil, id: "msg_#{id}", stop: "tool_use", tokens: [10, 4], content:) }
  end

  def answer(text, stop: "end_turn") = { json: message(text, stop:) }
  def replies(*replies) = replies.each { server.reply(**_1) }

  # An agent with one lookup and what `declare` adds; its step's first
  # attempt calls the lookup, then gets `first`; the attempt that replaces
  # it calls the lookup again, then gets `last`.
  def run_twice(name, safe:, first:, last: answer("Opens at 8."), workflow: asking("#{name}Workflow"), &declare)
    tool = lookup("#{name}Lookup", safe:)
    agent("#{name}Agent") do
      tools tool
      class_exec(&declare) if declare
    end
    replies(calling(tool, id: "toolu_a"), first, calling(tool, id: "toolu_b"), last)
    workflow.new(context: {}).run!
  end

  def retrying(name, **policy)
    asking(name).tap { |klass| klass.find_transition(:ask).instance_exec { retry_on Smith::AgentError, **policy } }
  end

  def models = server.requests.map { _1.body["model"] }
  def captured(result) = result.tool_results.map { _1[:tool_call_id] }
  def failure(result) = result.steps.last[:error]

  describe "the declaration" do
    it "is `capabilities { replay :safe }`, and unsafe by default" do
      safe = Class.new(Smith::Tool) { capabilities { replay :safe } }

      expect(safe.replay_safe?).to be(true)
      expect(safe.capabilities).to eq(replay: :safe)
      expect(Class.new(Smith::Tool).replay_safe?).to be(false)
      expect(Class.new(Smith::Tool) { capabilities { replay :unsafe } }.replay_safe?).to be(false)
      [true, "safe", nil].each do |value|
        expect { Class.new(Smith::Tool) { capabilities { replay value } } }
          .to raise_error(ArgumentError, "replay is :safe or :unsafe"), value.inspect
      end
    end

    it "is never inherited: a subclass is replay-safe only once it declares it itself" do
      safe = Class.new(Smith::Tool) do
        capabilities do
          replay :safe
          sensitivity :high
        end
      end
      child = Class.new(safe)
      guarded = Class.new(safe) { capabilities { privilege :authenticated } }
      declared = Class.new(safe) { capabilities { replay :safe } }

      expect([child.replay_safe?, guarded.replay_safe?, declared.replay_safe?]).to eq([false, false, true])
      expect([child.capabilities, guarded.capabilities])
        .to eq([{ sensitivity: :high }, { sensitivity: :high, privilege: :authenticated }])
      expect(declared.capabilities).to eq(sensitivity: :high, replay: :safe)
      expect(safe.replay_safe?).to be(true)

      expect([Class.new(child).replay_safe?, Class.new(declared).replay_safe?]).to eq([false, false])
      expect(Class.new(child) { capabilities { replay :safe } }.replay_safe?).to be(true)
      expect(Class.new(declared) { capabilities { replay :safe } }.replay_safe?).to be(true)
      expect(Class.new(Class.new(Smith::Tool) { capabilities { replay :safe } }).capabilities).to be_nil
    end

    it "makes a step whose tool is an undeclared subclass of a replay-safe one uncertain, until it declares" do
      parent = lookup("SpecReplayParentLookup", safe: true)
      [[false, Smith::ToolOutcomeUncertain, 1], [true, nil, 2]].each do |declares, error, ran|
        runs.clear
        tool = stub_const("SpecReplayChild#{declares}Lookup", Class.new(parent))
        tool.capabilities { replay :safe } if declares
        agent("SpecReplayChild#{declares}Agent") do
          tools tool
          fallback_models model: "claude-haiku-5-5", provider: :anthropic
        end
        replies(calling(tool, id: "toolu_a"), down, *(declares ? [calling(tool, id: "toolu_b"), answer("Ok.")] : []))

        result = asking("SpecReplayChild#{declares}Workflow").new(context: {}).run!

        expect([failure(result)&.class, runs.length]).to eq([error, ran]), "declares: #{declares}"
      end
    end
  end

  describe "output repair" do
    def repairing(name, safe:)
      schema = score_schema
      run_twice(name, safe:, first: answer('{"score":9}'), last: answer('{"score":3}')) { output_schema schema }
    end

    it "sends the step's messages again, so the tool loop runs again, and keeps only the repair's captures" do
      result = repairing("SpecSafeRepair", safe: true)

      expect([result.state, result.context[:answer], runs.length]).to eq([:done, { score: 3 }, 2])
      repair = server.requests[2].body["messages"]
      expect(repair.map { _1["role"] }).to eq(%w[user assistant user])
      expect(JSON.generate(repair)).not_to include("tool_use")
      expect(captured(result)).to eq(["toolu_b"])
    end

    it "is not made after a tool that is not replay-safe, which keeps its captures as before" do
      result = repairing("SpecUnsafeRepair", safe: false)

      expect(failure(result)).to be_a(Smith::ToolOutcomeUncertain)
      expect(failure(result).cause).to be_a(Smith::OutputInvalid)
      expect([runs.length, server.requests.length, captured(result)]).to eq([1, 2, ["toolu_a"]])
    end

    it "keeps the set-aside attempt's captures when its repair fails, as the step fails" do
      tool = lookup("SpecFailedRepairLookup", safe: true)
      schema = score_schema
      agent("SpecFailedRepairAgent") do
        tools tool
        output_schema schema
      end
      replies(calling(tool, id: "toolu_a"), answer('{"score":9}'), down)

      result = asking("SpecFailedRepairWorkflow").new(context: {}).run!

      expect(failure(result)).to be_a(Smith::OutputInvalid)
      expect([runs.length, captured(result)]).to eq([1, ["toolu_a"]])
    end
  end

  describe "the refusal fallback" do
    def refusing(name, safe:)
      run_twice(name, safe:, first: answer("No.", stop: "refusal")) do
        on_refusal fallback: "anthropic/claude-haiku-5-5"
      end
    end

    it "hands the step to the fallback model, whose tool loop runs again" do
      result = refusing("SpecSafeRefusal", safe: true)

      expect([result.state, result.context[:answer], runs.length]).to eq([:done, "Opens at 8.", 2])
      expect(models).to eq(%w[claude-sonnet-5-5 claude-sonnet-5-5 claude-haiku-5-5 claude-haiku-5-5])
      expect(captured(result)).to eq(["toolu_b"])
    end

    it "is not taken after a tool that is not replay-safe" do
      result = refusing("SpecUnsafeRefusal", safe: false)

      expect(failure(result)).to be_a(Smith::ToolOutcomeUncertain)
      expect(failure(result).cause).to be_a(Smith::OutputRefused)
      expect([runs.length, models.uniq]).to eq([1, ["claude-sonnet-5-5"]])
    end
  end

  describe "the truncation retry" do
    def truncated(name, safe:)
      run_twice(name, safe:, first: answer("Opens", stop: "max_tokens")) do
        on_truncation retry_with: { max_tokens: 2_000 }
      end
    end

    it "asks again with the larger limit, and the tool loop runs again" do
      result = truncated("SpecSafeTruncation", safe: true)

      expect([result.state, result.context[:answer], runs.length]).to eq([:done, "Opens at 8.", 2])
      expect(server.requests.map { _1.body["max_tokens"] }).to eq([500, 500, 2_000, 2_000])
      expect(captured(result)).to eq(["toolu_b"])
    end

    it "is not made after a tool that is not replay-safe" do
      result = truncated("SpecUnsafeTruncation", safe: false)

      expect(failure(result)).to be_a(Smith::ToolOutcomeUncertain)
      expect(failure(result).cause).to be_a(Smith::OutputTruncated)
      expect([runs.length, server.requests.length]).to eq([1, 2])
    end
  end

  describe "a provider failure after the tools" do
    def failing_over(name, safe:)
      run_twice(name, safe:, first: down) { fallback_models model: "claude-haiku-5-5", provider: :anthropic }
    end

    it "takes the fallback model, which runs the tool loop again" do
      result = failing_over("SpecSafeFallback", safe: true)

      expect([result.state, result.context[:answer], runs.length]).to eq([:done, "Opens at 8.", 2])
      expect(models).to eq(%w[claude-sonnet-5-5 claude-sonnet-5-5 claude-haiku-5-5 claude-haiku-5-5])
      expect(captured(result)).to eq(["toolu_b"])
    end

    it "keeps the failed attempt's captures when the fallback model fails too" do
      tool = lookup("SpecBothDownLookup", safe: true)
      agent("SpecBothDownAgent") do
        tools tool
        fallback_models model: "claude-haiku-5-5", provider: :anthropic
      end
      replies(calling(tool, id: "toolu_a"), down, down)

      result = asking("SpecBothDownWorkflow").new(context: {}).run!

      expect(failure(result)).to be_a(Smith::AgentError)
      expect([models, captured(result)]).to eq([%w[claude-sonnet-5-5 claude-sonnet-5-5 claude-haiku-5-5], ["toolu_a"]])
    end

    it "takes no fallback after a tool that is not replay-safe" do
      result = failing_over("SpecUnsafeFallback", safe: false)

      expect(failure(result)).to be_a(Smith::ToolOutcomeUncertain)
      expect([runs.length, models.uniq]).to eq([1, ["claude-sonnet-5-5"]])
    end
  end

  describe "the step's retries" do
    it "retries in process, and the failed attempt's captures go with it" do
      result = run_twice("SpecSafeRetry", safe: true, first: down,
                                          workflow: retrying("SpecSafeRetryWorkflow", attempts: 2))

      expect([result.state, runs.length, captured(result)]).to eq([:done, 2, ["toolu_b"]])
    end

    it "waits durably, stores the run without the failed attempt's captures, and runs the tools again" do
      tool = lookup("SpecSafeDurableLookup", safe: true)
      agent("SpecSafeDurableAgent") { tools tool }
      klass = retrying("SpecSafeDurableWorkflow", attempts: 2, backoff: 30, durable: true)
      replies(calling(tool, id: "toolu_a"), down)

      klass.new(context: {}).run_persisted!("replay-durable", adapter:)
      stored = JSON.parse(adapter.fetch("replay-durable"))
      expect([stored.dig("awaiting", "kind"), stored.dig("pending_retry", "error"), stored["tool_results"]])
        .to eq(["retry", "Smith::AgentError", []])

      wait = klass.restore("replay-durable", adapter:).awaiting
      klass.expire_wait!("replay-durable", token: wait.token, now: wait.deadline_at, adapter:)
      replies(calling(tool, id: "toolu_b"), answer("Opens at 8."))
      done = klass.restore("replay-durable", adapter:).run_persisted!("replay-durable", adapter:)

      expect([done.state, done.context[:answer], runs.length]).to eq([:done, "Opens at 8.", 2])
      expect(captured(done)).to eq(["toolu_b"])
    end

    it "keeps the failed attempt's captures when its retry wait cannot be entered" do
      tool = lookup("SpecShortLivedLookup", safe: true)
      agent("SpecShortLivedAgent") { tools tool }
      klass = retrying("SpecShortLivedWorkflow", attempts: 2, backoff: 600, durable: true)
      klass.persistence_ttl(300)
      replies(calling(tool, id: "toolu_a"), down)

      result = klass.new(context: {}).run_persisted!("short-lived", adapter:)

      expect(result.last_error.message).to match(/does not end within the persistence TTL/)
      expect(captured(result)).to eq(["toolu_a"])
    end

    it "enters no retry wait after a tool that is not replay-safe" do
      tool = lookup("SpecUnsafeDurableLookup", safe: false)
      agent("SpecUnsafeDurableAgent") { tools tool }
      klass = retrying("SpecUnsafeDurableWorkflow", attempts: 2, backoff: 30, durable: true)
      replies(calling(tool, id: "toolu_a"), down)

      result = klass.new(context: {}).run_persisted!("unsafe-durable", adapter:)

      expect(failure(result)).to be_a(Smith::ToolOutcomeUncertain)
      expect(klass.restore("unsafe-durable", adapter:)).not_to be_waiting
      expect([runs.length, captured(result)]).to eq([1, ["toolu_a"]])
    end

    it "keeps a paused tool loop's captures, which its retry continues from" do
      reserves = 0
      ledger = ledger_class.new(admit: ->(_amount) { (reserves += 1) != 2 })
      klass = with_stubbed_class("SpecPausedWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        budget_ledger { |_scope| ledger }
        seed_messages { |_context| [{ role: :user, content: "find the hours" }] }
        transition :ask, from: :idle, to: :done do
          execute :spec_ledger_agent, output_to: :answer
          retry_on Smith::BudgetUnavailable, attempts: 3
          on_failure :fail
        end
      end
      tool = lookup("SpecPausedLookup", safe: true)
      agent("SpecPausedAgent") { tools tool }
      replies(calling(tool, id: "toolu_a"), answer("Opens at 8."))

      result = klass.new(context: {}).run!

      expect([result.state, runs.length, captured(result)]).to eq([:done, 1, ["toolu_a"]])
    end
  end

  describe "a step whose tools are not all replay-safe" do
    it "is uncertain once any of them ran, in one round or before a safe one" do
      safe = lookup("SpecMixedSafeLookup", safe: true)
      unsafe = lookup("SpecMixedUnsafeLookup", safe: false)
      agent("SpecMixedAgent") do
        tools safe, unsafe
        fallback_models model: "claude-haiku-5-5", provider: :anthropic
      end
      klass = asking("SpecMixedWorkflow")
      replies(calling(safe, unsafe, id: "toolu_a"), down)
      together = klass.new(context: {}).run!

      expect(failure(together)).to be_a(Smith::ToolOutcomeUncertain)
      expect(runs.map(&:first)).to eq(%w[SpecMixedSafeLookup SpecMixedUnsafeLookup])

      runs.clear
      replies(calling(unsafe, id: "toolu_b"), calling(safe, id: "toolu_c"), down)
      apart = klass.new(context: {}).run!

      expect(failure(apart)).to be_a(Smith::ToolOutcomeUncertain)
      expect(runs.map(&:first)).to eq(%w[SpecMixedUnsafeLookup SpecMixedSafeLookup])
      expect(models.uniq).to eq(["claude-sonnet-5-5"])
    end

    it "is uncertain on a budget refusal carrying a paused loop that is not its run's own" do
      paid = []
      child = with_stubbed_class("SpecForeignPauseChild", workflow_class) do
        initial_state :idle
        transition :pay, from: :idle, to: :done do
          compute do |_step|
            Smith::Tool.current_tool_execution_tracker.mark_started!
            paid << :paid
            raise Smith::BudgetUnavailable.new("refused", continuation: [{ "role" => "assistant", "content" => "x" }])
          end
        end
      end
      parent = with_stubbed_class("SpecForeignPauseParent", workflow_class) do
        initial_state :idle
        state :failed
        transition :delegate, from: :idle, to: :done do
          workflow child
          retry_on Smith::BudgetUnavailable, attempts: 2
          on_failure :fail
        end
      end

      result = parent.new.run!

      expect(failure(result)).to be_a(Smith::ToolOutcomeUncertain)
      expect(paid).to eq([:paid])
    end

    describe "in a nested workflow" do
      # A child whose tool step succeeds and whose next step fails once.
      def failing_once_child(name)
        tries = []
        with_stubbed_class(name, workflow_class) do
          initial_state :idle
          seed_messages { |_context| [{ role: :user, content: "find the hours" }] }
          transition(:look, from: :idle, to: :looked) { execute :spec_ledger_agent, output_to: :answer }
          transition :finish, from: :looked, to: :done do
            compute { |step| (tries << step.attempt) && tries.one? && step.fail!("busy", retryable: true) }
          end
        end
      end

      # A parent that retries that child.
      def nested(name, safe:)
        tool = lookup("#{name}Lookup", safe:)
        agent("#{name}Agent") { tools tool }
        child = failing_once_child("#{name}Child")
        replies(calling(tool, id: "toolu_a"), answer("Opens at 8."))
        with_stubbed_class("#{name}Parent", workflow_class) do
          initial_state :idle
          state :failed
          transition :delegate, from: :idle, to: :done do
            workflow child
            retry_on attempts: 2
            on_failure :fail
          end
        end
      end

      it "carries safe tool evidence up as safe, so the parent retries its child" do
        parent = nested("SpecNestedSafe", safe: true)
        replies(calling(SpecNestedSafeLookup, id: "toolu_b"), answer("Opens at 8."))

        result = parent.new.run!

        expect([result.state, runs.length, server.requests.length]).to eq([:done, 2, 4])
      end

      it "carries a tool that is not replay-safe up as uncertain, as before" do
        result = nested("SpecNestedUnsafe", safe: false).new.run!

        expect(failure(result)).to be_a(Smith::ToolOutcomeUncertain)
        expect([runs.length, server.requests.length]).to eq([1, 2])
      end
    end
  end

  describe "a step replayed from the response memo" do
    let(:crash) { Class.new(Exception) } # rubocop:disable Lint/InheritException
    let(:memo) do
      Class.new do
        attr_accessor :crash_on

        def initialize = @records = {}
        def fetch(key) = @records[key]

        # Raises `crash_on` once, when a progress record ends in a tool's
        # result: the process died after the tools ran.
        def store(key, record)
          @records[key] = record
          return unless crash_on && !record["complete"] && record["messages"].last["role"] == "tool"

          error = crash_on
          self.crash_on = nil
          raise error
        end
      end.new
    end

    around do |example|
      saved = Smith.config.response_memo
      example.run
    ensure
      Smith.config.response_memo = saved
    end

    before { Smith.config.response_memo = memo }

    # A stored run whose step died after its tools ran.
    def crashed_after_tools(name, tools)
      agent("#{name}Agent") do
        tools(*tools)
        fallback_models model: "claude-haiku-5-5", provider: :anthropic
      end
      klass = asking("#{name}Workflow")
      replies(calling(*tools, id: "toolu_a"))
      memo.crash_on = crash
      expect { klass.new(context: {}).run_persisted!(name, adapter:) }.to raise_error(crash)
      klass
    end

    # That run restored and taken again, its first live round failing at
    # the provider.
    def replayed(name, *tools)
      klass = crashed_after_tools(name, tools)
      replies(down, calling(*tools, id: "toolu_b"), answer("Opens at 8."))
      klass.restore(name, adapter:).run_persisted!(name, adapter:)
    end

    it "takes the fallback when the kept tool results are all replay-safe, running the tools again" do
      result = replayed("SpecMemoSafe", lookup("SpecMemoSafeLookup", safe: true))

      expect([result.state, result.context[:answer], runs.length]).to eq([:done, "Opens at 8.", 2])
      expect(models).to eq(%w[claude-sonnet-5-5 claude-sonnet-5-5 claude-haiku-5-5 claude-haiku-5-5])
      expect(captured(result)).to eq(["toolu_b"])
    end

    it "is uncertain when a kept result is a tool's that is not replay-safe" do
      result = replayed("SpecMemoMixed", lookup("SpecMemoMixedSafeLookup", safe: true),
                        lookup("SpecMemoMixedUnsafeLookup", safe: false))

      expect(failure(result)).to be_a(Smith::ToolOutcomeUncertain)
      expect([runs.length, models.uniq]).to eq([2, ["claude-sonnet-5-5"]])
    end
  end

  describe "a fan-out" do
    let(:timeouts) { [] }

    def tool_request(tool, query) = Smith::Testing.tool_call(tool, query:)

    # Calls that wait on each other: b1b lets a1 go once b1 has captured,
    # then waits for a2, which comes after a1 captured.
    def gates
      b_ran = Queue.new
      a_ran = Queue.new
      wait = ->(queue, name) { queue.pop(timeout: 5) || (timeouts << name) }
      { "b1b" => -> { (b_ran << :go) && wait.call(a_ran, :a_ran) },
        "a1" => -> { wait.call(b_ran, :b_ran) }, "a2" => -> { a_ran << :go } }
    end

    # One replay-safe tool whose captures are all alike.
    def gated_lookup(gates)
      stub_const("SpecFanLookup", Class.new(Smith::Tool) do
        param :query, type: :string, required: true
        capabilities { replay :safe }
        capture_result(strict: true) { |_kwargs, _result| { found: true } }
        define_method(:perform) do |query:|
          gates[query]&.call
          { found: query }
        end
      end)
    end

    def fanning_out(name)
      with_stubbed_class(name, workflow_class) do
        initial_state :idle
        state :failed
        seed_messages { |_context| [{ role: :user, content: "find the hours" }] }
        transition :ask, from: :idle, to: :done do
          fan_out branches: { a: :spec_fan_a, b: :spec_fan_b }
          on_failure :fail
        end
      end
    end

    # Branch b's first attempt captures (b1), branch a captures (a1), b's
    # attempt captures again (b1b) and is set aside for a repair. Only b's
    # set-aside captures go, though a's are equal to them and came between.
    it "drops a branch's set-aside captures by identity, leaving another branch's made meanwhile" do
      tool = gated_lookup(gates)
      schema = score_schema
      fan_a = agent("SpecFanAAgent", register: :spec_fan_a) { tools tool }
      fan_b = agent("SpecFanBAgent", register: :spec_fan_b) do
        tools tool
        output_schema schema
      end
      Smith::Testing.stub_agent(fan_a, outputs: [tool_request(tool, "a1"), tool_request(tool, "a2"), "done"])
      Smith::Testing.stub_agent(fan_b, outputs: [tool_request(tool, "b1"), tool_request(tool, "b1b"), { score: 9 },
                                                 tool_request(tool, "b2"), { score: 3 }])

      result = fanning_out("SpecFanWorkflow").new(context: {}).run!

      expect([result.state, timeouts]).to eq([:done, []])
      expect(captured(result)).to contain_exactly("toolu_stub_1_1", "toolu_stub_2_1", "toolu_stub_4_1")
    ensure
      %i[spec_fan_a spec_fan_b].each { Smith::Agent::Registry.delete(_1) }
    end
  end
end
