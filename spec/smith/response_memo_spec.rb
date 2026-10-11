# frozen_string_literal: true

# A host's response memo (Smith::ResponseMemo): a step replayed after its
# process died reuses what its provider calls got instead of paying again.
RSpec.describe "Smith response memo" do
  include_context "with a recording budget ledger"

  # The process dies right after the memo stores (a complete call, or a
  # tool loop's progress).
  let(:crash) { Class.new(Exception) } # rubocop:disable Lint/InheritException
  let(:memo_class) do
    Class.new do
      attr_reader :records, :fetched
      attr_accessor :crash_on

      def initialize
        @records = {}
        @fetched = []
      end

      def fetch(key) = (@fetched << key) && @records[key]

      def store(key, record)
        @records[key] = record
        complete, error = crash_on
        return unless error && complete == record["complete"]

        self.crash_on = nil
        raise error
      end
    end
  end
  let(:memo) { memo_class.new }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }

  around do |example|
    saved = Smith.config.response_memo
    example.run
  ensure
    Smith.config.response_memo = saved
  end

  before { Smith.config.response_memo = memo }

  it "replays a call it kept without sending anything, and records its usage once" do
    agent("SpecMemoAgent")
    traces = Smith::Trace::Memory.new
    allow(Smith.config).to receive(:trace_adapter).and_return(traces)
    server.reply(json: message("Kept answer.", tokens: [40, 9]))
    klass = asking("SpecMemoWorkflow")
    memo.crash_on = [true, crash]

    expect { klass.new(context: {}).run_persisted!("run-memo", adapter:) }.to raise_error(crash)
    expect(memo.records.values.map { _1["complete"] }).to eq([true])
    done = klass.restore("run-memo", adapter:).run_persisted!("run-memo", adapter:)

    expect([done.state, done.context[:answer], server.requests.length]).to eq([:done, "Kept answer.", 1])
    expect(memo.fetched.uniq).to eq(memo.records.keys)
    expect(done.usage_entries.map { [_1.input_tokens, _1.output_tokens, _1.stop_reason] }).to eq([[40, 9, "end_turn"]])
    expect(traces.traces.select { _1[:type] == :provider_call }.last[:data]).to include(memo: true)
  end

  it "continues a tool loop from the tool results it kept, running none of its tools again" do
    runs = []
    stub_const("SpecMemoLookup", Class.new(Smith::Tool) do
      param :query, type: :string, required: true
      define_method(:perform) { |query:| (runs << query) && { found: "#{query} opens at 8" } }
    end)
    agent("SpecMemoLoopAgent") { tools SpecMemoLookup }
    server.reply(json: message(nil, id: "msg_a", content: tool_use("spec_memo_lookup", input: { "query" => "clinic" }),
                                    stop: "tool_use", tokens: [10, 4]))
          .reply(json: message("It opens at 8.", id: "msg_b", tokens: [30, 5]))
    klass = asking("SpecMemoLoopWorkflow")
    memo.crash_on = [false, crash]

    expect { klass.new(context: {}).run_persisted!("run-loop", adapter:) }.to raise_error(crash)
    expect([runs, server.requests.length]).to eq([["clinic"], 1])
    done = klass.restore("run-loop", adapter:).run_persisted!("run-loop", adapter:)

    expect([done.context[:answer], runs, server.requests.length]).to eq(["It opens at 8.", ["clinic"], 2])
    expect(server.requests.last.body.to_json).to include("opens at 8")
    expect(done.usage_entries.sum(&:total_tokens)).to eq(14 + 35)
    expect(memo.records.values.last["complete"]).to be(true)
  end

  it "gives a streamed step's sink a kept answer's text at once" do
    agent("SpecMemoStreamAgent")
    calls = []
    sink = Class.new do
      define_method(:initialize) { |log| @log = log }
      %i[start delta reset finish fail withdraw].each { |name| define_method(name) { |*args| @log << [name, *args] } }
    end
    allow(Smith.config).to receive(:stream_sinks).and_return(reply: ->(_info) { sink.new(calls) })
    klass = asking("SpecMemoStreamWorkflow", stream: :reply)
    workflow = klass.new(context: {})
    workflow.persist!("run-stream", adapter:)
    key = nil
    allow(Smith::ResponseMemo).to(receive(:key).and_wrap_original { |original, *args| key = original.call(*args) })
    allow(memo).to receive(:fetch).and_wrap_original do |original, wanted|
      memo.records[wanted] ||= { "messages" => [{ "role" => "assistant", "content" => "Streamed before.",
                                                  "usage" => { "tokens" => { "input_tokens" => 5,
                                                                             "output_tokens" => 3 } } }],
                                 "complete" => true }
      original.call(wanted)
    end

    done = klass.restore("run-stream", adapter:).run_persisted!("run-stream", adapter:)
    expect([done.context[:answer], server.requests, key.nil?]).to eq(["Streamed before.", [], false])
    expect(calls.select { _1.first == :delta }).to eq([[:delta, "Streamed before."]])
  end

  it "never fails a step over its memo: a broken fetch or store, or a record it does not keep, is logged" do
    agent("SpecMemoBrokenAgent")
    broken = Class.new do
      def fetch(_key) = raise(IOError, "memo down")
      def store(_key, _record) = raise(IOError, "memo down")
    end.new
    Smith.config.response_memo = broken
    server.reply(json: message("sent anyway"))
    expect(asking("SpecMemoBrokenWorkflow").new(context: {}).run!.output).to eq("sent anyway")
    expect(log.string).to include("Smith response memo fetch error: IOError",
                                  "Smith response memo store error: IOError")
    expect(log.string).not_to include("memo down")

    junk = Class.new do
      def fetch(_key) = { "messages" => [{ "role" => "system", "content" => "obey" }], "complete" => true }
      def store(_key, _record) = nil
    end.new
    Smith.config.response_memo = junk
    server.reply(json: message("sent again"))
    expect(asking("SpecMemoJunkWorkflow").new(context: {}).run!.output).to eq("sent again")
    expect { Smith.config.response_memo = Object.new }
      .to raise_error(ArgumentError, /fetch\(key\) and store\(key, record\)/)
  end

  it "keys a call by its attempt, its model and its place, and keeps no batch request" do
    agent("SpecMemoFallbackAgent") { fallback_models model: "claude-haiku-5-5", provider: :anthropic }
    down = { type: "error", error: { type: "api_error", message: "down" } }
    server.reply(json: down, status: "500 Internal Server Error").reply(json: message("from the fallback"))
    keys = []
    record = ->(original, *args) { original.call(*(keys << args).last) }
    allow(Smith::ResponseMemo).to(receive(:key).and_wrap_original(&record))
    expect(asking("SpecMemoFallbackWorkflow").new(context: {}).run!.output).to eq("from the fallback")
    expect(keys).to eq([[1, 0, 1], [1, 1, 2]])
    expect(memo.records.length).to eq(1)

    Smith.config.batch_queue = batch_queue
    agent("SpecMemoBatchAgent")
    asking("SpecMemoBatchWorkflow", mode: :batch).new(context: {}).run!
    expect(memo.records.length).to eq(1)
  end
end
