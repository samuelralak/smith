# frozen_string_literal: true

require "logger"
require "stringio"

# What two reviews of streaming steps found (slice 10), each pinned.
RSpec.describe "Smith streaming: review fixes" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:sinks) { [] }
  let(:sink_class) do
    Class.new do
      attr_reader :calls

      def initialize = @calls = []
      def start(info) = @calls << [:start, info]
      def delta(text) = @calls << [:delta, text]
      def reset(reason) = @calls << [:reset, reason]
      def finish(output) = @calls << [:finish, output]
      def fail(error_class) = @calls << [:fail, error_class]
      def names = @calls.map(&:first)
    end
  end
  let(:server) { SseServer.new }
  let(:log) { StringIO.new }

  around do |example|
    saved_sinks = Smith.config.stream_sinks
    logger = Smith.config.logger
    config = RubyLLM.config
    saved = %i[anthropic_api_key anthropic_api_base].to_h { [_1, config.public_send(_1)] }
    example.run
  ensure
    server.close
    saved.each { |key, value| config.public_send(:"#{key}=", value) }
    Smith.config.stream_sinks = saved_sinks
    Smith.config.logger = logger
  end

  before do
    RubyLLM.configure do |config|
      config.anthropic_api_key = "test"
      config.anthropic_api_base = server.url
    end
    Smith.config.logger = Logger.new(log)
    Smith.config.stream_sinks = { reply: ->(_info) { sink_class.new.tap { sinks << _1 } } }
    allow_any_instance_of(workflow_class).to receive(:sleep)
  end

  def text_round(texts, stop: "end_turn", id: "msg_1")
    [{ type: "message_start", message: { id:, model: "m", usage: { input_tokens: 3, output_tokens: 0 } } },
     { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
     *texts.map { { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: _1 } } },
     { type: "content_block_stop", index: 0 },
     *([{ type: "message_delta", delta: { stop_reason: stop }, usage: { output_tokens: 2 } }] if stop),
     { type: "message_stop" }]
  end

  def tool_round(tool, id: "msg_1", text: nil)
    [{ type: "message_start", message: { id:, model: "m", usage: { input_tokens: 3, output_tokens: 0 } } },
     *([{ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: } }] if text),
     { type: "content_block_start", index: 0,
       content_block: { type: "tool_use", id: "toolu_1", name: tool, input: {} } },
     { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"query":"x"}' } },
     { type: "content_block_stop", index: 0 },
     { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 4 } },
     { type: "message_stop" }]
  end

  def live_agent(name, &body)
    Smith::Agent::Registry.delete(:spec_review_agent)
    klass = with_stubbed_class(name, agent_class) do
      register_as :spec_review_agent
      model "claude-opus-4-1", provider: :anthropic, assume_model_exists: true
    end
    klass.class_exec(&body) if body
    klass
  end

  def streaming(name, stream: :reply, &body)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "hi" }] }
      transition :ask, from: :idle, to: :done do
        execute :spec_review_agent, stream: stream
        instance_exec(&body) if body
        on_failure :fail
      end
    end
  end

  def failure(result) = result.steps.last[:error]

  it "stores each response's stop reason, message id and mode in its usage entry, as an unstreamed step does" do
    stub_const("SpecReviewLookup", Class.new(Smith::Tool) do
      param :query, type: :string, required: true
      def perform(query:) = { found: query }
    end)
    live_agent("SpecReviewLoopAgent") { tools SpecReviewLookup }
    server.reply(events: tool_round("spec_review_lookup", id: "msg_a"))
          .reply(events: text_round(%w[Do ne], id: "msg_b"))

    result = streaming("SpecReviewLoopWorkflow").new(context: {}).run!

    expect(result.output).to eq("Done")
    entries = result.usage_entries.map { [_1.stop_reason, _1.provider_message_id, _1.mode] }
    expect(entries).to eq([["tool_use", "msg_a", :stream], ["end_turn", "msg_b", :stream]])
    expect(sinks.sole.calls.select { _1.first == :delta }.map(&:last)).to eq(%w[Do ne])

    server.reply(json: { type: "message", id: "msg_c", role: "assistant", model: "m", stop_reason: "end_turn",
                         content: [{ type: "text", text: "Plain" }], usage: { input_tokens: 3, output_tokens: 2 } })
    live_agent("SpecReviewPlainAgent")
    plain = streaming("SpecReviewPlainWorkflow", stream: nil).new(context: {}).run!
    expect(plain.usage_entries.map { [_1.stop_reason, _1.provider_message_id, _1.mode] })
      .to eq([["end_turn", "msg_c", nil]])
  end

  it "keeps the facts of a failed streamed call's completed rounds in their usage entries" do
    stub_const("SpecReviewFailLookup", Class.new(Smith::Tool) do
      param :query, type: :string, required: true
      def perform(query:) = { found: query }
    end)
    live_agent("SpecReviewPartialAgent") { tools SpecReviewFailLookup }
    busy = JSON.generate(type: "error", error: { type: "overloaded_error", message: "busy" })
    overloaded = "event: error\ndata: #{busy}\n\n"
    server.reply(events: tool_round("spec_review_fail_lookup", id: "msg_p")).reply(events: [overloaded])

    result = streaming("SpecReviewPartialWorkflow").new(context: {}).run!

    expect(result.state).to eq(:failed)
    partial = result.usage_entries.find { _1.attempt_kind == :partial_attempt }
    expect([partial.stop_reason, partial.provider_message_id, partial.mode]).to eq(["tool_use", "msg_p", :stream])
  end

  it "reads only the step's own stream: a tool's own streamed call cannot change the step's stop reason" do
    inner_base = server.url
    stub_const("SpecReviewAsker", Class.new(Smith::Tool) do
      param :query, type: :string, required: true
      define_method(:perform) do |query:|
        chat = RubyLLM.chat(model: "claude-opus-4-1", provider: :anthropic, assume_model_exists: true)
        chat.add_message(role: :user, content: query)
        { asked: chat.complete { |_chunk| nil }.content, via: inner_base }
      end
    end)
    live_agent("SpecReviewOuterAgent") { tools SpecReviewAsker }
    server.reply(events: tool_round("spec_review_asker", id: "msg_o1"))
          .reply(events: text_round(["I cannot"], stop: "refusal", id: "msg_inner"))
          .reply(events: text_round(["All good"], id: "msg_o2"))

    result = streaming("SpecReviewOuterWorkflow").new(context: {}).run!

    expect(failure(result)).to be_nil
    expect(result.output).to eq("All good")
    expect(result.usage_entries.map(&:provider_message_id)).to eq(%w[msg_o1 msg_o2])
  end

  it "counts a real stream that ended before its stop event as cut off" do
    live_agent("SpecReviewCutAgent")
    server.reply(events: text_round(["The ", "answer"], stop: nil))

    result = streaming("SpecReviewCutWorkflow").new(context: {}).run!

    expect(failure(result)).to be_a(Smith::OutputTruncated)
    expect(failure(result).stop_reason).to eq("stream_incomplete")
    expect(sinks.sole.names).to eq(%i[start delta delta fail])
  end

  it "starts <think> filtering over with each request of a tool loop, and traces each attempt's mode" do
    stub_const("SpecReviewThinkLookup", Class.new(Smith::Tool) do
      param :query, type: :string, required: true
      def perform(query:) = { found: query }
    end)
    live_agent("SpecReviewThinkLoopAgent") { tools SpecReviewThinkLookup }
    server.reply(events: tool_round("spec_review_think_lookup", text: "<think>unfinished"))
          .reply(events: text_round(["Answer"], id: "msg_2"))
    traces = Smith::Trace::Memory.new
    allow(Smith.config).to receive(:trace_adapter).and_return(traces)

    expect(streaming("SpecReviewThinkLoopWorkflow").new(context: {}).run!.output).to eq("Answer")
    expect(sinks.sole.calls.select { _1.first == :delta }.map(&:last).join).to eq("Answer")
    call = traces.traces.find { _1[:type] == :provider_call }[:data]
    expect(call.slice(:mode, :stop_reason, :provider_message_id))
      .to eq(mode: :stream, stop_reason: "end_turn", provider_message_id: "msg_2")
  end

  it "keeps <think> text out of the stream, as RubyLLM keeps it out of the message" do
    live_agent("SpecReviewThinkAgent")
    server.reply(events: text_round(["<thi", "nk>secret ", "plan</th", "ink>Hi", " there <", "b>"]))

    result = streaming("SpecReviewThinkWorkflow").new(context: {}).run!

    expect(result.output).to eq("Hi there <b>")
    expect(sinks.sole.calls.select { _1.first == :delta }.map(&:last).join).to eq("Hi there <b>")
  end

  it "gives the accepted output to the sink once the step is stored, and the store's error when it fails" do
    live_agent("SpecReviewStoredAgent")
    adapter = Smith::PersistenceAdapters::Memory.new
    stored = []
    allow(adapter).to receive(:store_versioned).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap { stored << sinks.last&.names&.last }
    end
    server.reply(events: text_round(["First"]))

    streaming("SpecReviewStoredWorkflow").new(context: {}).run_persisted!("run-stored", adapter:)
    expect(stored).to eq([nil, :delta])
    expect(sinks.sole.names.last).to eq(:finish)

    conflict = Smith::PersistenceAdapters::Memory.new
    calls = 0
    allow(conflict).to receive(:store_versioned).and_wrap_original do |original, *args, **kwargs|
      calls += 1
      raise Smith::PersistenceVersionConflict.new(key: "run-conflict", expected: 1, actual: 2) if calls == 2

      original.call(*args, **kwargs)
    end
    server.reply(events: text_round(["Lost"]))
    conflicted = streaming("SpecReviewConflictWorkflow").new(context: {})
    expect { conflicted.run_persisted!("run-conflict", adapter: conflict) }.to raise_error(Smith::PersistenceVersionConflict)
    expect(sinks.last.names).to eq(%i[start delta fail])
    expect(sinks.last.calls.last).to eq([:fail, Smith::PersistenceVersionConflict])
  end

  it "gives a stored run's output to the sink when the run moves on without storing it" do
    live_agent("SpecReviewMovesAgent")
    adapter = Smith::PersistenceAdapters::Memory.new
    server.reply(events: text_round(["One"])).reply(events: text_round(["Two"]))
    klass = with_stubbed_class("SpecReviewMovesWorkflow", workflow_class) do
      initial_state :idle
      seed_messages { |_context| [{ role: :user, content: "hi" }] }
      transition(:one, from: :idle, to: :middle) { execute :spec_review_agent, stream: :reply }
      transition(:two, from: :middle, to: :done) { execute :spec_review_agent, stream: :reply }
    end
    workflow = klass.new(context: {})
    workflow.persist!("run-moves", adapter:)

    workflow.advance!
    expect(sinks.sole.names.last).to eq(:delta)
    workflow.advance!
    expect(sinks.map { _1.names.last }).to eq(%i[finish delta])
    workflow.run!
    expect(sinks.map { _1.names.last }).to eq(%i[finish finish])
  end

  it "logs a sink or sink callable that raises a ScriptError, and the step goes on" do
    live_agent("SpecReviewScriptAgent")
    raising = Class.new { def delta(_text) = raise(NotImplementedError, "abstract") }
    Smith.config.stream_sinks = { reply: ->(_info) { raising.new } }
    server.reply(events: text_round(["ok"]))
    expect(streaming("SpecReviewScriptWorkflow").new(context: {}).run!.output).to eq("ok")

    Smith.config.stream_sinks = { reply: ->(_info) { raise NotImplementedError, "abstract" } }
    server.reply(json: { type: "message", id: "m", role: "assistant", model: "m", stop_reason: "end_turn",
                         content: [{ type: "text", text: "ok" }], usage: { input_tokens: 1, output_tokens: 1 } })
    expect(streaming("SpecReviewScriptCallableWorkflow").new(context: {}).run!.output).to eq("ok")
    expect(log.string).to include("Smith stream sink :reply delta error: NotImplementedError",
                                  "Smith stream sink :reply call error: NotImplementedError")
  end

  it "hands the sink a frozen copy of the execution key" do
    live_agent("SpecReviewKeyAgent")
    infos = []
    Smith.config.stream_sinks = { reply: ->(info) { (infos << info) && nil } }
    server.reply(json: { type: "message", id: "m", role: "assistant", model: "m", stop_reason: "end_turn",
                         content: [{ type: "text", text: "ok" }], usage: { input_tokens: 1, output_tokens: 1 } })
    workflow = streaming("SpecReviewKeyWorkflow").new(context: {})
    workflow.run_persisted!("run-key", adapter: Smith::PersistenceAdapters::Memory.new)

    key = infos.sole[:execution_key]
    expect([key, key.frozen?, key.equal?(workflow.instance_variable_get(:@persistence_key))])
      .to eq(["run-key", true, false])
  end

  it "ends the sink with reset(:retry_wait) when a durable retry waits before any provider call" do
    live_agent("SpecReviewEarlyAgent")
    attempts = 0
    early_input = lambda do |_ctx|
      attempts += 1
      raise Smith::AgentError, "not ready" if attempts == 1

      [{ role: :user, content: "hi" }]
    end
    workflow = with_stubbed_class("SpecReviewEarlyWorkflow", workflow_class) do
      initial_state :idle
      state :failed
      transition :ask, from: :idle, to: :done do
        execute :spec_review_agent, stream: :reply, input: early_input
        retry_on attempts: 2, backoff: 30, durable: true
        on_failure :fail
      end
    end.new(context: {})

    workflow.run!
    expect(workflow).to be_waiting
    expect(sinks.sole.calls).to eq([%i[reset retry_wait]])
  end

  describe Smith::Streaming::ThinkTags do
    it "strips thinking across chunks, starts over each request, and drops a partial tag at a request's end" do
      tags = described_class.new
      out = ["a<th", "ink>x</thi", "nk>b", "<", "c"].map { tags.strip(_1, 1) }
      expect(out.join).to eq("ab<c")
      expect(tags.strip("<think>x y</think>z", 1)).to eq("z")
      expect(tags.strip("<think>open", 1)).to eq("")
      expect(tags.strip("still", 1)).to eq("")
      expect(tags.strip("fresh", 2)).to eq("fresh")
      expect(tags.strip("tail <thin", 2)).to eq("tail ")
      expect(tags.strip("next", 3)).to eq("next")
      expect(tags.strip(nil, 3)).to be_nil
    end
  end
end
