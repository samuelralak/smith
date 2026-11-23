# frozen_string_literal: true

require "digest"
require "json"
require "open3"

# A persisted orchestrate run whose process dies once the response memo has
# kept a call, restored and run on. Each later round's message carries the
# workers' execution ids, named by each worker's place (its run, step,
# round, task and copy), so the restored run asks its orchestrator what it
# asked before and every kept call replays: it sends, holds and charges
# what an uncut run does, and ends the same.
RSpec.describe "Smith::Workflow::OrchestratorWorker restored after its process died" do
  include_context "with a recording budget ledger"

  # The process dies once, right after the memo keeps its `die_after`th
  # whole call. Each fetch notes whether it found a record.
  let(:crash) { Class.new(Exception) } # rubocop:disable Lint/InheritException
  let(:memo_class) do
    Class.new do
      attr_accessor :crash, :die_after
      attr_reader :records, :found

      def initialize
        @records = {}
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
  let(:hours) { { "task_id" => "t1", "input" => "hours" } }
  let(:address) { { "task_id" => "t2", "input" => "address" } }
  # Three rounds: two tasks, then one of them twice, then the final.
  let(:calls) { ["round 1", hours, address, "round 2", hours, hours, "round 3"] }
  let(:uuid) { /\A\h{8}-\h{4}-8\h{3}-[89ab]\h{3}-\h{12}\z/ }

  around do |example|
    saved = Smith.config.response_memo
    example.run
  ensure
    Smith.config.response_memo = saved
  end

  before do
    text = { type: "string" }
    task = { type: "object", properties: { task_id: text, input: text } }
    final = { type: "object", properties: { summary: text } }
    decision = schema("decision", { tasks: { type: "array", items: task }, final: })
    agent("SpecRestoreOrchestrator", register: :spec_restore_orchestrator) { output_schema decision }
    agent("SpecRestoreWorker", register: :spec_restore_worker)
  end

  def schema(name, properties, keys: nil)
    Class.new do
      define_singleton_method(:required_keys) { keys } if keys
      define_method(:to_json_schema) { { name:, schema: { type: "object", properties: } } }
    end
  end

  # One orchestrate step for each of `steps`, by name, from and to.
  def orchestrating(name, led, steps: { research: %i[idle done] })
    step = { orchestrator: :spec_restore_orchestrator, worker: :spec_restore_worker, max_workers: 2,
             max_delegation_rounds: 3, task_schema: schema("task", {}, keys: %i[task_id input]),
             worker_output_schema: schema("finding", { finding: { type: "string" } }, keys: %i[finding]),
             final_output_schema: schema("summary", {}, keys: %i[summary]), output_to: :report }
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger { |_scope| led }
      seed_messages { |_context| [{ role: :user, content: "research the clinic" }] }
      steps.each do |named, (from, to)|
        transition named, from:, to: do
          orchestrate(**step)
          on_failure :fail
        end
      end
    end
  end

  # The text of a request's last message.
  def said(request)
    content = request.body.fetch("messages").last.fetch("content")
    content.is_a?(String) ? content : content.map { _1["text"] }.join
  end

  # What a request asks: its orchestration round, or a worker's task.
  def asking(request)
    said = said(request)
    return JSON.parse(said) if said.start_with?("{")

    "round #{said[/\A\[smith:orchestration-round\] (\d+)/, 1] || 1}"
  end

  # Answers each request by what it asks, so one sent again gets the same
  # reply; only the final says it was asked again, as a model may word a
  # second answer differently. `first` lists round 1's tasks.
  def answer_by_request(first: [hours, address])
    asked = Hash.new(0)
    server.answer do |request|
      ask = asking(request)
      asked[ask] += 1
      reply = case ask
              when "round 1" then { tasks: first }
              when "round 2" then { tasks: [hours, hours] }
              when "round 3" then { final: { summary: "opens at 8#{" (asked again)" if asked[ask] > 1}" } }
              else { finding: "#{ask["input"]} found" }
              end
      tokens = ask.is_a?(Hash) ? [20, 4] : [30, 8]
      { json: message(JSON.generate(reply), id: "msg_#{asked.values.sum}", tokens:) }
    end
  end

  # What a run (persisted under `key`) sent, held and charged, and how it
  # ended.
  def story(run, key, led, from)
    result = run.run_persisted!(key, adapter:)
    charged(led, from).merge(
      output: [result.state, result.output, result.last_error&.message], report: saved_report(run.class, key),
      usage: run.usage_entries.map { [_1.agent_name, _1.input_tokens, _1.output_tokens] }
    )
  end

  def saved_report(klass, key) = klass.restore(key, adapter:).to_state[:context][:report]

  # The requests sent since `from`, and each hold and settlement with its
  # amount and how many keys they took.
  def charged(led, from)
    { sent: server.requests.drop(from).map { asking(_1) }, ledger: led.calls.map { [_1.first, _1[2]] },
      hold_keys: led.keys.uniq.length }
  end

  def uncut_story
    Smith.config.response_memo = memo_class.new
    led = ledger_class.new
    from = server.requests.length
    story(orchestrating("SpecRestoreUncutWorkflow", led).new(context: {}), "run-uncut", led, from)
  end

  # Each result a round's message gave the orchestrator: its task and its id.
  def fed_back(requests)
    requests.filter_map do |request|
      said = said(request)
      JSON.parse(said.split("[smith:worker-results]\n").last) if said.start_with?("[smith:orchestration-round]")
    end
  end

  describe "a persisted run cut once the memo has kept a call" do
    # Rounds 2 and 3 are asked with execution ids in their messages: on
    # 0.16.0 each was sent again after a restore, and charged again.
    {
      1 => "round 1's orchestrator reply", 2 => "round 1's first worker reply",
      3 => "round 1's worker replies", 4 => "round 2's orchestrator reply", 5 => "round 2's first worker reply",
      6 => "round 2's worker replies", 7 => "round 3's orchestrator reply, the final"
    }.each do |die_after, kept|
      it "restored after #{kept} was kept, sends, holds and charges what an uncut run does and ends the same" do
        answer_by_request
        uncut = uncut_story
        expect(uncut[:sent]).to eq(calls)

        answer_by_request
        memo = Smith.config.response_memo = memo_class.new
        memo.crash = crash
        memo.die_after = die_after
        led = ledger_class.new
        klass = orchestrating("SpecRestoreCut#{die_after}Workflow", led)
        from = server.requests.length
        expect { klass.new(context: {}).run_persisted!("run-cut", adapter:) }.to raise_error(crash)
        expect(server.requests.length - from).to eq(die_after)
        kept_before = memo.found.length

        expect(story(klass.restore("run-cut", adapter:), "run-cut", led, from)).to eq(uncut)
        expect(memo.found.drop(kept_before).first(die_after)).to eq([true] * die_after)
        expect(memo.records.length).to eq(calls.length)
      end
    end
  end

  describe "a worker's execution_id" do
    before { Smith.config.response_memo = nil }

    it "is a UUID no two workers of a run share, whatever their step, round, task or copy, and runs never do" do
      answer_by_request
      steps = { research: %i[idle researched], recheck: %i[researched done] }
      klass = orchestrating("SpecRestoreIdsWorkflow", ledger, steps:)

      ids = Array.new(2) do
        from = server.requests.length
        klass.new(context: {}).run!
        fed_back(server.requests.drop(from)).flatten.map { _1.fetch("execution_id") }
      end

      expect(ids.map(&:length)).to eq([8, 8])
      expect(ids.flatten.uniq.length).to eq(16)
      expect(ids.flatten).to all(match(uuid))
    end

    # From its definition, with Digest and JSON alone: the version 8 UUID
    # shape of the key of the worker's position (the run's namespace, the
    # step, the round from 0, the task's content digest and copy) under a
    # `worker_execution` segment. Restored an hour or a process later, the
    # same run must send the same ids.
    it "is the UUID its definition gives for its run, step, round, task and copy" do
      namespace = "11111111-1111-4111-8111-111111111111"
      answer_by_request
      klass = orchestrating("SpecRestorePinnedWorkflow", ledger)
      state = klass.new(context: {}).to_state.merge(execution_namespace: namespace)
      klass.from_state(JSON.parse(JSON.generate(state))).run!
      content = ->(task) { Digest::SHA256.hexdigest(JSON.generate(task.sort.to_h)) }
      expected = [[[0, hours, 1], [0, address, 1]], [[1, hours, 1], [1, hours, 2]]].map do |round|
        round.map do |at, task, copy|
          path = [["step", 1, "research"], ["round", at], ["task", content.call(task), copy], ["worker_execution"]]
          hex = Digest::SHA256.hexdigest(JSON.generate(["smith.idempotency.v1", namespace, path, nil]))
          variant = ((hex[16].to_i(16) & 0x3) | 0x8).to_s(16)
          "#{hex[0, 8]}-#{hex[8, 4]}-8#{hex[13, 3]}-#{variant}#{hex[17, 3]}-#{hex[20, 12]}"
        end
      end

      expect(fed_back(server.requests).map { |round| round.map { _1.fetch("execution_id") } }).to eq(expected)
    end

    it "gives away no idempotency key host code gets where the worker runs" do
      keys = []
      SpecRestoreWorker.define_method(:after_completion) do |result, _context|
        keys.push(Smith::IdempotencyKey.current, Smith::IdempotencyKey.current("charge"))
        result
      end
      answer_by_request
      orchestrating("SpecRestoreKeysWorkflow", ledger).new(context: {}).run!

      ids = fed_back(server.requests).flatten.map { _1.fetch("execution_id").delete("-") }
      expect([ids.length, keys.length]).to eq([4, 8])
      expect(ids.product(keys).select { |id, key| key.start_with?(id[0, 12]) }).to eq([])
    end

    it "is the same in a restored run, whatever order its orchestrator lists the tasks in" do
      klass = orchestrating("SpecRestoreSameWorkflow", ledger)
      payload = JSON.generate(klass.new(context: {}).to_state)

      rounds = [[hours, address], [address, hours]].map do |first|
        answer_by_request(first:)
        from = server.requests.length
        klass.from_state(JSON.parse(payload)).run!
        fed_back(server.requests.drop(from)).map { |round| round.map { _1.values_at("task", "execution_id") } }
      end

      expect(rounds.first.map(&:length)).to eq([2, 2])
      expect(rounds.last.first).to eq(rounds.first.first.reverse)
      expect(rounds.last.last).to eq(rounds.first.last)
    end

    # In fresh processes, under Smith::Testing stubs: one dies once round 2's
    # decision is kept, another restores its payload and memo and finishes.
    it "is the same in another process, which replays every call the first one kept" do
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
            raise Killed if @cut && @records.size == 3
          end
        end
        Schema = lambda do |name, properties, keys = []|
          Class.new do
            define_singleton_method(:required_keys) { keys }
            define_method(:to_json_schema) { { name:, schema: { type: "object", properties: } } }
          end
        end
        text = { type: "string" }
        task = { type: "object", properties: { task_id: text } }
        Decision = Schema.call("decision", { tasks: { type: "array", items: task },
                                            final: { type: "object", properties: { summary: text } } })
        Finding = Schema.call("finding", { finding: text }, %i[finding])
        %w[Orchestrator Worker].each do |name|
          Object.const_set(name, Class.new(Smith::Agent) do
            register_as name.downcase.to_sym
            model "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true
          end)
        end
        Orchestrator.output_schema(Decision)
        class Research < Smith::Workflow
          initial_state :idle
          state :failed
          seed_messages { |_context| [{ role: :user, content: "research the clinic" }] }
          transition :research, from: :idle, to: :done do
            orchestrate orchestrator: :orchestrator, worker: :worker, max_workers: 2, max_delegation_rounds: 3,
                        task_schema: Schema.call("task", {}, %i[task_id]), worker_output_schema: Finding,
                        final_output_schema: Schema.call("summary", {}, %i[summary])
            on_failure :fail
          end
        end
        task = { task_id: "t1" }
        adapter = Smith::PersistenceAdapters::Memory.new
        if ARGV.first == "cut"
          Smith.config.response_memo = Memo.new({}, cut: true)
          Smith::Testing.stub_agent(:orchestrator, outputs: [{ tasks: [task] }, { tasks: [task, task] }])
          Smith::Testing.stub_agent(:worker, outputs: { finding: "kept" })
          begin
            Research.new(context: {}).run_persisted!("run", adapter:)
          rescue Killed
            puts JSON.generate(payload: adapter.fetch("run"), records: Smith.config.response_memo.records)
          end
        else
          kept = JSON.parse($stdin.read)
          adapter.store("run", kept.fetch("payload"))
          memo = Smith.config.response_memo = Memo.new(kept.fetch("records"))
          orchestrator = Smith::Testing.stub_agent(:orchestrator, outputs: { final: { summary: "done" } })
          worker = Smith::Testing.stub_agent(:worker, outputs: { finding: "live" })
          done = Research.restore("run", adapter:).run_persisted!("run", adapter:)
          asked = orchestrator.calls.map { _1.last.content.to_s[/\\A\\[smith:orchestration-round\\] \\d+/] }
          puts JSON.generate(state: done.state, output: done.output, asked:, workers: worker.calls.length,
                             replayed: memo.found.first(3))
        end
      RUBY
      lib = File.expand_path("../../../lib", __dir__)
      cut, cut_status = Open3.capture2e(RbConfig.ruby, "-I#{lib}", "-e", script, "cut")
      restored, status = Open3.capture2e(RbConfig.ruby, "-I#{lib}", "-e", script, "restore",
                                         stdin_data: cut.lines.last.to_s)

      expect([cut_status.success?, status.success?]).to eq([true, true]), restored
      expect(JSON.parse(restored.lines.last.to_s))
        .to eq("state" => "done", "output" => { "summary" => "done" }, "asked" => ["[smith:orchestration-round] 3"],
               "workers" => 2, "replayed" => [true] * 3)
    end
  end
end
