# frozen_string_literal: true

require "logger"
require "stringio"

RSpec.describe "Smith streaming: a step's reply streamed to a host sink" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:sink_class) do
    Class.new do
      attr_reader :calls

      def initialize = @calls = []
      def start(info) = @calls << [:start, info]
      def delta(text) = @calls << [:delta, text]
      def reset(reason) = @calls << [:reset, reason]
      def finish(output) = @calls << [:finish, output]
      def fail(error_class) = @calls << [:fail, error_class]
    end
  end
  let(:sink) { sink_class.new }
  let(:opened) { [] }
  let(:reply_class) { Struct.new(:content, :input_tokens, :output_tokens, :raw, :role) }
  let(:anthropic) { RubyLLM::Providers::Anthropic.new(RubyLLM::Configuration.new.tap { _1.anthropic_api_key = "k" }) }
  let(:blocks) { [] }

  around do |example|
    sinks = Smith.config.stream_sinks
    example.run
  ensure
    Smith.config.stream_sinks = sinks
  end

  before do
    Smith.config.stream_sinks = { reply: listening(sink) }
    allow_any_instance_of(workflow_class).to receive(:sleep)
  end

  # A sink callable that records each step's info and gives it `step_sink`.
  def listening(step_sink) = ->(info) { (opened << info) && step_sink }

  # What the sink heard, a start as the model it named.
  def heard = sink.calls.map { |name, value| name == :start ? [:start, value[:model]] : [name, value] }

  # A reply that streams `texts` as Anthropic's events, ending with `stop`.
  def said(*texts, stop: "end_turn", id: "msg_1", tokens: 1)
    events = texts.map do |text|
      { "type" => "content_block_delta", "index" => 0, "delta" => { "type" => "text_delta", "text" => text } }
    end
    { content: texts.join, tokens:,
      events: [{ "type" => "message_start", "message" => { "id" => id, "usage" => {} } }, *events,
               { "type" => "message_delta", "delta" => { "stop_reason" => stop }, "usage" => {} }] }
  end

  # A chat answering one reply. A streamed call passes the reply's events
  # through RubyLLM's own Anthropic chunk builder, as a real stream does,
  # and gives the chunks to the block; the reply may then raise.
  let(:chat_class) do
    Class.new do
      attr_reader :params

      def initialize(reply, answer, provider, blocks)
        @reply = reply
        @answer = answer
        @provider = provider
        @blocks = blocks
        @params = {}
      end

      def add_message(_message) = nil
      def with_schema(_schema) = self
      def with_params(**given) = @params.merge!(given) && self

      def complete(&block)
        @blocks << !block.nil?
        @reply.fetch(:events, []).each { |event| block.call(@provider.send(:build_chunk, event)) } if block
        raise @reply[:error] if @reply[:error]

        @answer
      end
    end
  end

  # Chats answering each reply in turn, the last one again and again.
  def chat_answering(replies)
    lambda do |**_options|
      reply = replies.length > 1 ? replies.shift : replies.first
      answer = reply_class.new(reply[:content], 1, reply.fetch(:tokens, 1), nil, :assistant)
      chat_class.new(reply, answer, anthropic, blocks)
    end
  end

  def agent(name, replies, register: :spec_stream_agent, model: "claude-opus-5-5", provider: :anthropic, &body)
    klass = with_stubbed_class(name, agent_class) do
      register_as register
      model(model, provider:)
    end
    klass.class_exec(&body) if body
    allow(klass).to receive(:chat, &chat_answering(replies))
    klass
  end

  def streaming(name, agent_name = :spec_stream_agent, output_to: nil, &body)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "hi" }] }
      transition :ask, from: :idle, to: :done do
        execute agent_name, stream: :reply, output_to: output_to
        instance_exec(&body) if body
        on_failure :fail
      end
    end
  end

  def failure(result) = result.steps.last[:error]

  describe "the declaration" do
    it "names a sink with a Symbol, is refused on a parallel step, and shows in the graph" do
      klass = workflow_class
      declare = ->(**options) { Class.new(klass) { transition(:t, from: :a, to: :b) { execute :x, **options } } }

      expect { declare.call(stream: "reply") }.to raise_error(Smith::WorkflowError, /must name a sink with a Symbol/)
      expect { declare.call(stream: :reply, parallel: true) }
        .to raise_error(Smith::WorkflowError, /not available on a parallel step/)
      graph = declare.call(stream: :reply, parallel: false).graph
      expect(graph.transition_snapshots.sole.to_h[:stream]).to eq(:reply)
      expect(graph.transitions.values.sole.stream).to eq(:reply)
      expect(declare.call.graph.transition_snapshots.sole.to_h).not_to have_key(:stream)
    end

    it "takes the sinks as a Hash of callables by name" do
      callable = listening(sink)
      expect { Smith.config.stream_sinks = [callable] }.to raise_error(ArgumentError, /must be a Hash/)
      [nil, "", 1].each do |name|
        expect { Smith.config.stream_sinks = { name => callable } }.to raise_error(ArgumentError, /names must be/)
      end
      expect { Smith.config.stream_sinks = { reply: sink } }.to raise_error(ArgumentError, /must be a callable/)
      Smith.config.stream_sinks = { "reply" => callable }
      expect(Smith.config.stream_sinks).to eq(reply: callable)
      expect(Smith.config.stream_sinks).to be_frozen
    end

    it "reports a missing sink, and a model path that may send each reply whole" do
      tool = Class.new(Smith::Tool) { def perform(**) = nil }
      diagnostics = lambda do |name, **model, &body|
        Smith::Agent::Registry.delete(:spec_stream_agent)
        agent("#{name}Agent", [said("x")], **model) { instance_exec(tool, &body) if body }
        streaming("#{name}Workflow").runtime_readiness.runtime_diagnostics
                                    .select { _1.transition == :ask }.map { [_1.severity, _1.code] }
      end

      mode = Smith.config.openai_api_mode
      Smith.config.openai_api_mode = :auto
      expect(diagnostics.call("SpecStreamReady")).to eq([])
      Smith.config.stream_sinks = {}
      expect(diagnostics.call("SpecStreamMissing")).to eq([%i[error stream_sink_missing]])
      Smith.config.stream_sinks = { reply: listening(sink) }
      openai = { model: "gpt-5", provider: :openai }
      expect(diagnostics.call("SpecStreamOpenAI", **openai) { tools _1 }).to eq([%i[warning stream_whole_replies]])
      expect(diagnostics.call("SpecStreamFallback") { tools(_1) && fallback_models("openai/gpt-5") })
        .to eq([%i[warning stream_whole_replies]])
      expect(diagnostics.call("SpecStreamInferred", model: "gpt-5", provider: nil) { tools _1 })
        .to eq([%i[warning stream_whole_replies]])
      expect(diagnostics.call("SpecStreamNoTools", **openai)).to eq([])
      expect(diagnostics.call("SpecStreamAnthropicTools") { tools _1 }).to eq([])
      Smith.config.openai_api_mode = :off
      expect(diagnostics.call("SpecStreamOff", **openai) { tools _1 }).to eq([])
    ensure
      Smith.config.openai_api_mode = mode
    end
  end

  describe "what a sink hears" do
    it "hears each call start, its text chunks and the accepted output, and none of its thinking" do
      thinking = { "type" => "content_block_delta", "index" => 0,
                   "delta" => { "type" => "thinking_delta", "thinking" => "hmm" } }
      reply = said("Hel", "lo")
      reply[:events].insert(1, thinking)
      agent("SpecHeardAgent", [reply])
      workflow = streaming("SpecHeardWorkflow").new(context: {})

      expect(workflow.run_persisted!("run-1", adapter: Smith::PersistenceAdapters::Memory.new).output).to eq("Hello")
      expect(heard).to eq([[:start, "claude-opus-5-5"], [:delta, "Hel"], [:delta, "lo"], [:finish, "Hello"]])
      expect(sink.calls.first.last).to eq(stream: :reply, execution_key: "run-1", transition: :ask, attempt: 1,
                                          model: "claude-opus-5-5", provider: "anthropic")
      expect(sink.calls.first.last).to be_frozen
      expect(opened).to eq([{ stream: :reply, execution_key: "run-1", transition: :ask }])
      expect(opened.sole).to be_frozen
      expect(blocks).to eq([true])
    end

    it "streams no step whose sink is nil, and goes on unstreamed when the sink's callable raises" do
      log = StringIO.new
      logger = Smith.config.logger
      Smith.config.logger = Logger.new(log)
      agent("SpecUnheardAgent", [said("x")])
      Smith.config.stream_sinks = { reply: listening(nil) }
      expect(streaming("SpecUnheardWorkflow").new(context: {}).run!.output).to eq("x")
      Smith.config.stream_sinks = { reply: ->(_info) { raise ArgumentError, "secret" } }
      expect(streaming("SpecBrokenSinkWorkflow").new(context: {}).run!.output).to eq("x")

      expect([opened.size, blocks]).to eq([1, [false, false]])
      expect(log.string).to include("Smith stream sink :reply call error: ArgumentError")
      expect(log.string).not_to include("secret")
    ensure
      Smith.config.logger = logger
    end

    it "finishes with the output the step accepted, after after_completion and output_to" do
      agent("SpecAcceptedAgent", [said("hi")]) do
        define_method(:after_completion) { |content, _context| content.upcase }
      end
      workflow = streaming("SpecAcceptedWorkflow", output_to: :answer).new(context: {})
      workflow.run!

      expect(heard.last).to eq([:finish, "HI"])
      expect(workflow.to_state[:context][:answer]).to eq("HI")
    end

    it "withdraws a cut-off reply, its stop reason read from the stream, before the larger request" do
      agent("SpecCutOffAgent", [said("Hal", "f", stop: "max_tokens"), said("Whole")]) do
        on_truncation retry_with: { max_tokens: 64_000 }
      end

      expect(streaming("SpecCutOffWorkflow").new(context: {}).run!.output).to eq("Whole")
      expect(heard).to eq([[:start, "claude-opus-5-5"], [:delta, "Hal"], [:delta, "f"], %i[reset truncation],
                           [:start, "claude-opus-5-5"], [:delta, "Whole"], [:finish, "Whole"]])
    end

    it "counts a streamed reply without a stop reason as cut off when it used the whole output limit" do
      limit = Smith::Providers::OutputLimit::ANTHROPIC_DEFAULT
      allow(Smith::Providers::OutputLimit).to receive(:anthropic_default).and_return(limit)
      silent = { content: "x", tokens: limit, events: [{ "type" => "content_block_delta", "index" => 0,
                                                         "delta" => { "type" => "text_delta", "text" => "x" } }] }
      agent("SpecSilentAgent", [silent])

      result = streaming("SpecSilentWorkflow").new(context: {}).run!
      expect(failure(result)).to be_a(Smith::OutputTruncated)
      expect(failure(result).stop_reason).to eq("output_limit_reached")
      expect(heard.last).to eq([:fail, Smith::OutputTruncated])

      Smith::Agent::Registry.delete(:spec_stream_agent)
      agent("SpecSilentShortAgent", [silent.merge(tokens: limit - 1)])
      expect(streaming("SpecSilentShortWorkflow").new(context: {}).run!.output).to eq("x")

      Smith::Agent::Registry.delete(:spec_stream_agent)
      agent("SpecSilentRetriedAgent", [said("Ha", stop: "max_tokens"), silent.merge(tokens: limit + 1)]) do
        on_truncation retry_with: { max_tokens: 64_000 }
      end
      expect(streaming("SpecSilentRetriedWorkflow").new(context: {}).run!.output).to eq("x")
    end

    it "withdraws a reply sent for repair, and one a refusal hands to another model" do
      schema = Class.new do
        def to_json_schema
          { name: "r", schema: { type: "object", required: ["a"], properties: { a: { type: "string" } } } }
        end
      end
      agent("SpecRepairAgent", [said("nope"), said('{"a":"ok"}')]) { output_schema schema }
      expect(streaming("SpecRepairWorkflow").new(context: {}).run!.output).to eq("a" => "ok")
      expect(heard.select { _1.first == :reset }).to eq([%i[reset repair]])

      sink.calls.clear
      Smith::Agent::Registry.delete(:spec_stream_agent)
      agent("SpecRefusedAgent", [said("No", stop: "refusal"), said("Yes")]) do
        on_refusal fallback: "anthropic/claude-sonnet-5-5"
      end
      expect(streaming("SpecRefusedWorkflow").new(context: {}).run!.output).to eq("Yes")
      expect(heard).to eq([[:start, "claude-opus-5-5"], [:delta, "No"], %i[reset fallback],
                           [:start, "claude-sonnet-5-5"], [:delta, "Yes"], [:finish, "Yes"]])
    end

    it "withdraws a failed call's text before a fallback model, and before the step's next attempt" do
      down = RubyLLM::ServerError.new("down")
      agent("SpecFallbackAgent", [said("Par").merge(error: down), said("Full")]) do
        fallback_models "anthropic/claude-sonnet-5-5"
      end
      expect(streaming("SpecFallbackWorkflow").new(context: {}).run!.output).to eq("Full")
      expect(heard).to eq([[:start, "claude-opus-5-5"], [:delta, "Par"], %i[reset fallback],
                           [:start, "claude-sonnet-5-5"], [:delta, "Full"], [:finish, "Full"]])

      sink.calls.clear
      Smith::Agent::Registry.delete(:spec_stream_agent)
      agent("SpecRetriedAgent", [said("Par").merge(error: down), said("Full")])
      workflow = streaming("SpecRetriedWorkflow") { retry_on attempts: 2, backoff: 0.01 }.new(context: {})
      expect(workflow.run!.output).to eq("Full")
      expect(sink.calls.map { |name, value| name == :start ? value[:attempt] : name })
        .to eq([1, :delta, :reset, 2, :delta, :finish])
      expect(sink.calls[2]).to eq(%i[reset retry])
    end

    it "withdraws while a durable retry waits, and streams the resumed attempt to a sink of its own" do
      sinks = []
      Smith.config.stream_sinks = { reply: ->(_info) { sink_class.new.tap { sinks << _1 } } }
      agent("SpecDurableAgent", [said("Par").merge(error: RubyLLM::ServerError.new("down")), said("Full")])
      workflow = streaming("SpecDurableWorkflow") { retry_on attempts: 2, backoff: 30, durable: true }
                 .new(context: {})

      workflow.run!
      expect(workflow).to be_waiting
      expect(sinks.sole.calls.map(&:first)).to eq(%i[start delta reset])
      expect(sinks.sole.calls.last).to eq(%i[reset retry_wait])
      workflow.expire_wait!(token: workflow.awaiting.token, now: workflow.awaiting.deadline_at)

      expect(workflow.run!.state).to eq(:done)
      expect(sinks.last.calls.map(&:first)).to eq(%i[start delta finish])
      expect(sinks.last.calls.first.last[:attempt]).to eq(2)
    end

    it "tells the sink the step failed, with the error's class" do
      agent("SpecFailedAgent", [said("x").merge(error: RubyLLM::UnauthorizedError.new("no"))])
      result = streaming("SpecFailedWorkflow").new(context: {}).run!

      expect(heard).to eq([[:start, "claude-opus-5-5"], [:delta, "x"], [:fail, failure(result).class]])
    end

    it "fails the step before its call when the sink is not registered" do
      klass = agent("SpecUnsunkAgent", [said("x")])
      Smith.config.stream_sinks = {}
      result = streaming("SpecUnsunkWorkflow").new(context: {}).run!

      expect(failure(result)).to be_a(Smith::StreamSinkMissing)
      expect(failure(result).message).to include(":reply")
      expect(klass).not_to have_received(:chat)
    end

    it "logs a sink that raises, by the error's class only, and the step goes on" do
      log = StringIO.new
      logger = Smith.config.logger
      Smith.config.logger = Logger.new(log)
      sink.define_singleton_method(:delta) { |_text| raise ArgumentError, "secret text" }
      sink.define_singleton_method(:finish) { |_output| raise "finish broke" }
      agent("SpecRaisingSinkAgent", [said("a", "b")])

      expect(streaming("SpecRaisingSinkWorkflow").new(context: {}).run!.output).to eq("ab")
      expect(log.string).to include("Smith stream sink :reply delta error: ArgumentError",
                                    "Smith stream sink :reply finish error: RuntimeError")
      expect(log.string).not_to include("secret text")
    ensure
      Smith.config.logger = logger
    end

    it "calls only the methods a sink defines" do
      log = StringIO.new
      logger = Smith.config.logger
      Smith.config.logger = Logger.new(log)
      texts = []
      only_delta = Object.new
      only_delta.define_singleton_method(:delta) { |text| texts << text }
      Smith.config.stream_sinks = { reply: listening(only_delta) }
      agent("SpecDeltaOnlyAgent", [said("a", "b")])

      expect(streaming("SpecDeltaOnlyWorkflow").new(context: {}).run!.output).to eq("ab")
      expect(texts).to eq(%w[a b])
      expect(log.string).to eq("")
    ensure
      Smith.config.logger = logger
    end

    it "streams only the steps declared to, and a step that does not stream calls its chat without a block" do
      agent("SpecFirstAgent", [said("one")])
      agent("SpecSecondAgent", [said("two")], register: :spec_second_agent)
      klass = with_stubbed_class("SpecTwoStepWorkflow", workflow_class) do
        initial_state :idle
        seed_messages { |_context| [{ role: :user, content: "hi" }] }
        transition(:ask, from: :idle, to: :asked) { execute :spec_stream_agent, stream: :reply }
        transition(:again, from: :asked, to: :done) { execute :spec_second_agent }
      end

      expect(klass.new(context: {}).run!.output).to eq("two")
      expect(heard).to eq([[:start, "claude-opus-5-5"], [:delta, "one"], [:finish, "one"]])
      expect(blocks).to eq([true, false])
    end
  end

  describe Smith::Streaming::Session do
    it "sends text only between a start and its withdrawal, and settles once" do
      session = described_class.new(sink, { stream: :reply, execution_key: "k", transition: :ask }.freeze)

      session.delta("early")
      session.withdraw(:retry)
      session.start(attempt: 1, model: "m", provider: "p")
      [nil, "", 7, "text"].each { session.delta(_1) }
      session.withdraw(:repair)
      session.withdraw(:repair)
      session.delta("late")
      session.start(attempt: 1, model: "n", provider: "p")
      session.finish("done")
      session.fail(RuntimeError)
      session.start(attempt: 2, model: "o", provider: "p")
      session.delta("after")
      session.withdraw(:retry)

      expect(heard).to eq([[:start, "m"], [:delta, "text"], %i[reset repair], [:start, "n"], [:finish, "done"]])
    end
  end

  describe Smith::Providers::StreamFacts do
    let(:config) do
      RubyLLM::Configuration.new.tap do |config|
        %i[anthropic_api_key openai_api_key gemini_api_key mistral_api_key deepseek_api_key openrouter_api_key
           bedrock_api_key bedrock_secret_key].each { config.public_send(:"#{_1}=", "k") }
        config.bedrock_region = "us-east-1"
      end
    end

    def read(provider, *events)
      described_class.collect { events.each { provider.send(:build_chunk, _1) } }
    end

    def provider(name) = RubyLLM::Providers.const_get(name).new(config)

    it "reads each provider's stop reason and message id from its stream events" do
      start = ->(id) { { "type" => "message_start", "message" => { "id" => id, "usage" => {} } } }
      stop = ->(reason) { { "type" => "message_delta", "delta" => { "stop_reason" => reason }, "usage" => {} } }
      anthropic_provider = provider(:Anthropic)
      tool_round = [start.call("m1"), stop.call("tool_use"), start.call("m2")]
      expect(read(anthropic_provider, *tool_round, stop.call("end_turn")))
        .to eq(stop_reason: "end_turn", provider_message_id: "m2")
      expect(read(anthropic_provider, *tool_round)).to eq(provider_message_id: "m2")
      no_reason = { "type" => "message_delta", "delta" => {}, "usage" => {} }
      expect(read(anthropic_provider, start.call("m1"), no_reason)).to eq(provider_message_id: "m1")
      expect(read(anthropic_provider, start.call("m1"), stop.call("max_tokens"), no_reason))
        .to eq(stop_reason: "max_tokens", provider_message_id: "m1")

      chunk = lambda do |delta, reason = nil|
        { "id" => "c1", "choices" => [{ "delta" => delta, "finish_reason" => reason }] }
      end
      usage = { "id" => "c1", "choices" => [], "usage" => { "prompt_tokens" => 1 } }
      %i[OpenAI Mistral DeepSeek OpenRouter].each do |name|
        expect(read(provider(name), chunk.call({ "content" => "hi" }), chunk.call({}, "length"), usage))
          .to eq({ stop_reason: "length", provider_message_id: "c1" }), name.to_s
      end
      expect(read(provider(:OpenAI), chunk.call({ "refusal" => "I can't" }), chunk.call({}, "stop"))[:stop_reason])
        .to eq("refusal")
      expect(read(provider(:OpenAI), chunk.call({ "refusal" => "" }), chunk.call({}, "stop"))[:stop_reason])
        .to eq("stop")

      candidate = lambda do |reason|
        { "responseId" => "r1", "candidates" => [{ "content" => { "parts" => [] }, "finishReason" => reason }] }
      end
      expect(read(provider(:Gemini), candidate.call(nil), candidate.call("SAFETY")))
        .to eq(stop_reason: "SAFETY", provider_message_id: "r1")
      expect(read(provider(:Gemini), { "promptFeedback" => { "blockReason" => "OTHER" } }))
        .to eq(stop_reason: "prompt_blocked")
      expect(read(provider(:Gemini), { "promptFeedback" => {} })).to eq({})

      bedrock = provider(:Bedrock)
      text = { "contentBlockDelta" => { "delta" => { "text" => "x" } } }
      expect(read(bedrock, text, { "stopReason" => "max_tokens" })).to eq(stop_reason: "max_tokens")
      expect(read(bedrock, { "messageStop" => { "stopReason" => "end_turn" } })).to eq(stop_reason: "end_turn")
      expect(read(bedrock, { "stopReason" => 3 })).to eq({})
    end

    it "collects only inside collect, keeps an outer collection, bounds what it keeps, and never raises" do
      anthropic_provider = provider(:Anthropic)
      long = "x" * 1000
      anthropic_provider.send(:build_chunk, { "type" => "message_start", "message" => { "id" => "outside" } })

      outer = described_class.collect do
        anthropic_provider.send(:build_chunk, { "type" => "message_start", "message" => { "id" => long } })
        inner = described_class.collect do
          described_class.observe({ "type" => "message_start", "message" => { "id" => "in" } })
        end
        expect(inner).to eq(provider_message_id: "in")
        [{ "choices" => "x" }, { "choices" => [1] }, { "candidates" => 5 }, { "messageStop" => "x" },
         { "type" => "message_delta", "delta" => "x" }, { "type" => 1 }, nil, "text", { "stopReason" => 3 }]
          .each { described_class.observe(_1) }
        anthropic_provider.send(:build_chunk, { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" } })
      end

      expect(outer[:provider_message_id].bytesize).to be <= Smith::Providers::ResponseFacts::MAX_BYTES
      expect(outer[:provider_message_id]).to start_with("xxx")
      expect(outer[:stop_reason]).to eq("end_turn")
    end

    it "settles a streamed reply's facts over its raw body's, and by its usage when no stop reason came" do
      message = Struct.new(:raw, :output_tokens)
      body = { "type" => "message", "id" => "raw", "stop_reason" => "end_turn" }

      expect(described_class.settle(message.new(body, 9), { provider_message_id: "s" }, 9))
        .to eq(stop_reason: "end_turn", provider_message_id: "s")
      expect(described_class.settle(message.new("spent", 9), {}, 9)).to eq(stop_reason: "output_limit_reached")
      expect(described_class.settle(message.new("spent", 10), {}, 9)).to eq(stop_reason: "output_limit_reached")
      expect(described_class.settle(message.new("spent", 8), {}, 9)).to eq({})
      expect(described_class.settle(message.new("spent", 9), {}, nil)).to eq({})
      expect(described_class.settle(message.new("spent", nil), {}, 9)).to eq({})
      expect(described_class.settle(message.new("spent", 9), { stop_reason: "stop" }, 9)).to eq(stop_reason: "stop")
      expect(Smith::Providers::StopReason.classify("output_limit_reached")).to eq(:truncated)
    end

    it "is installed once on each of RubyLLM's streaming modules" do
      observer = described_class::Observer
      modules = %i[Anthropic OpenAI Gemini OpenRouter Bedrock].map { RubyLLM::Providers.const_get(_1)::Streaming }
      verbose = $VERBOSE
      $VERBOSE = nil
      load File.expand_path("../../lib/smith/providers/stream_facts.rb", __dir__)
      $VERBOSE = verbose

      modules.each { |streaming| expect(streaming.ancestors.count(described_class::Observer)).to eq(1), streaming.name }
      expect(RubyLLM::Providers::Mistral.ancestors).to include(observer)
      expect(RubyLLM::Providers::VertexAI.ancestors).to include(observer)
    end
  end

  describe "over RubyLLM's own streaming" do
    let(:server) { SseServer.new }

    around do |example|
      config = RubyLLM.config
      keys = %i[anthropic_api_key anthropic_api_base openai_api_key openai_api_base gemini_api_key gemini_api_base]
      saved = keys.to_h { [_1, config.public_send(_1)] }
      example.run
    ensure
      server.close
      saved.each { |key, value| config.public_send(:"#{key}=", value) }
    end

    before do
      RubyLLM.configure do |config|
        %i[anthropic openai gemini].each do |name|
          config.public_send(:"#{name}_api_key=", "test")
          config.public_send(:"#{name}_api_base=", name == :openai ? "#{server.url}/v1" : server.url)
        end
      end
    end

    def live_agent(name, model, provider, &body)
      klass = with_stubbed_class(name, agent_class) do
        register_as :spec_stream_agent
        model model, provider:, assume_model_exists: true
      end
      klass.class_exec(&body) if body
      klass
    end

    def anthropic_events(texts, stop)
      [{ type: "message_start", message: { id: "msg_1", model: "m", usage: { input_tokens: 3, output_tokens: 0 } } },
       { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
       *texts.map { { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: _1 } } },
       { type: "content_block_stop", index: 0 },
       { type: "message_delta", delta: { stop_reason: stop }, usage: { output_tokens: 2 } },
       { type: "message_stop" }]
    end

    it "streams an Anthropic reply, retrying a cut-off one with a larger limit" do
      server.reply(events: anthropic_events(%w[Hal f], "max_tokens"))
            .reply(events: anthropic_events(%w[Who le], "end_turn"))
      live_agent("SpecLiveAnthropicAgent", "claude-opus-4-1", :anthropic) do
        on_truncation retry_with: { max_tokens: 64_000 }
      end

      expect(streaming("SpecLiveAnthropicWorkflow").new(context: {}).run!.output).to eq("Whole")
      expect(heard).to eq([[:start, "claude-opus-4-1"], [:delta, "Hal"], [:delta, "f"], %i[reset truncation],
                           [:start, "claude-opus-4-1"], [:delta, "Who"], [:delta, "le"], [:finish, "Whole"]])
      expect(server.requests.map { [_1.path, _1.body["stream"], _1.body["max_tokens"]] })
        .to eq([["/v1/messages", true, 4096], ["/v1/messages", true, 64_000]])
    end

    it "streams an OpenAI Chat Completions reply and reads its cut-off" do
      chunk = lambda do |delta, reason = nil|
        { id: "c1", object: "chat.completion.chunk", choices: [{ index: 0, delta:, finish_reason: reason }] }
      end
      server.reply(events: [chunk.call({ role: "assistant", content: "Ha" }), chunk.call({ content: "lf" }),
                            chunk.call({}, "length"), "data: [DONE]\n\n"])
      live_agent("SpecLiveOpenAIAgent", "gpt-4.1", :openai)

      result = streaming("SpecLiveOpenAIWorkflow").new(context: {}).run!
      expect(failure(result)).to be_a(Smith::OutputTruncated)
      expect(failure(result).stop_reason).to eq("length")
      expect(heard).to eq([[:start, "gpt-4.1"], [:delta, "Ha"], [:delta, "lf"], [:fail, Smith::OutputTruncated]])
      expect(server.requests.sole.path).to eq("/v1/chat/completions")
    end

    it "streams a Gemini reply and reads its refusal" do
      part = lambda do |text, reason = nil|
        { responseId: "r1",
          candidates: [{ content: { role: "model", parts: [{ text: }] }, finishReason: reason }.compact] }
      end
      server.reply(events: [part.call("I can"), part.call("not", "SAFETY")])
      live_agent("SpecLiveGeminiAgent", "gemini-2.5-pro", :gemini)

      result = streaming("SpecLiveGeminiWorkflow").new(context: {}).run!
      expect(failure(result)).to be_a(Smith::OutputRefused)
      expect(heard).to eq([[:start, "gemini-2.5-pro"], [:delta, "I can"], [:delta, "not"],
                           [:fail, Smith::OutputRefused]])
      expect(server.requests.sole.path).to start_with("/models/gemini-2.5-pro:streamGenerateContent")
    end

    it "sends a reply from Smith's OpenAI Responses path as one delta, keeping its stop reason" do
      body = lambda do |status, reason|
        { id: "resp_1", object: "response", model: "gpt-5", status:, incomplete_details: reason && { reason: },
          output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text: "Whole reply" }] }],
          usage: { input_tokens: 3, output_tokens: 2 } }
      end
      server.reply(json: body.call("completed", nil)).reply(json: body.call("incomplete", "max_output_tokens"))
      live_agent("SpecLiveResponsesAgent", "gpt-5", :openai) { params openai_api_mode: :responses }

      expect(streaming("SpecLiveResponsesWorkflow").new(context: {}).run!.output).to eq("Whole reply")
      expect(heard).to eq([[:start, "gpt-5"], [:delta, "Whole reply"], [:finish, "Whole reply"]])
      expect(server.requests.first.path).to eq("/v1/responses")

      sink.calls.clear
      expect(failure(streaming("SpecLiveResponsesCutWorkflow").new(context: {}).run!)).to be_a(Smith::OutputTruncated)
      message = Struct.new(:content, :model_id)
      [nil, ""].each do |content|
        quiet = message.new(content, "gpt-5")
        expect(Smith::Providers::OpenAI::Responses.with_whole_chunk(quiet) { raise "no chunk" }).to be(quiet)
      end
    end
  end
end
