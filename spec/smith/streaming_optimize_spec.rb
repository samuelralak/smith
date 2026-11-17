# frozen_string_literal: true

# An `optimize` step streams its generator's replies, round after round: the
# evaluator's verdicts never reach the sink, and a round the evaluator or
# `before_eval` rejects is withdrawn before the generator writes again.
RSpec.describe "Smith streaming an optimize step" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:sink_class) do
    Class.new do
      attr_reader :calls

      def initialize = @calls = []
      def start(info) = @calls << [:start, info[:model]]
      def delta(text) = @calls << [:delta, text]
      def reset(reason) = @calls << [:reset, reason]
      def finish(output) = @calls << [:finish, output]
      def fail(error_class) = @calls << [:fail, error_class]
    end
  end
  let(:sink) { sink_class.new }
  let(:reply_class) { Struct.new(:content, :input_tokens, :output_tokens, :raw, :role) }
  let(:anthropic) { RubyLLM::Providers::Anthropic.new(RubyLLM::Configuration.new.tap { _1.anthropic_api_key = "k" }) }
  let(:blocks) { Hash.new { |hash, key| hash[key] = [] } }
  let(:verdict_schema) do
    Class.new do
      def to_json_schema
        { name: "verdict", schema: { type: "object", required: %w[accept feedback],
                                     properties: { accept: { type: "boolean" }, feedback: { type: "string" } } } }
      end
    end
  end
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
        @answer
      end
    end
  end

  around do |example|
    sinks = Smith.config.stream_sinks
    example.run
  ensure
    Smith.config.stream_sinks = sinks
  end

  before { Smith.config.stream_sinks = { draft: ->(_info) { sink } } }

  def said(*texts)
    events = texts.map do |text|
      { "type" => "content_block_delta", "index" => 0, "delta" => { "type" => "text_delta", "text" => text } }
    end
    { content: texts.join,
      events: [{ "type" => "message_start", "message" => { "id" => "msg_1", "usage" => {} } }, *events,
               { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" }, "usage" => {} }] }
  end

  def verdict(accept) = { content: JSON.generate(accept:, feedback: accept ? "ok" : "Make it shorter") }

  def chat_for(reply, calls)
    chat_class.new(reply, reply_class.new(reply[:content], 1, 1, nil, :assistant), anthropic, calls)
  end

  def agent(name, register, replies)
    klass = with_stubbed_class(name, agent_class) do
      register_as register
      model "claude-sonnet-5-5", provider: :anthropic
    end
    calls = blocks[register]
    allow(klass).to receive(:chat) { chat_for(replies.length > 1 ? replies.shift : replies.first, calls) }
    klass
  end

  def drafting(name, max_rounds: 2, **optimize)
    schema = verdict_schema
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "write a line" }] }
      transition :draft, from: :idle, to: :done do
        optimize generator: :spec_stream_writer, evaluator: :spec_stream_judge, max_rounds:,
                 evaluator_schema: schema, stream: :draft, **optimize
        on_failure :fail
      end
    end
  end

  it "streams each round the generator writes, withdraws the one rejected, and never streams a verdict" do
    agent("SpecStreamWriter", :spec_stream_writer, [said("Too ", "long"), said("Short")])
    agent("SpecStreamJudge", :spec_stream_judge, [verdict(false), verdict(true)])

    result = drafting("SpecStreamedOptimize").new(context: {}).run!

    expect(result.output).to eq("Short")
    expect(sink.calls).to eq(
      [
        [:start, "claude-sonnet-5-5"], [:delta, "Too "], [:delta, "long"], %i[reset rejected],
        [:start, "claude-sonnet-5-5"], [:delta, "Short"], [:finish, "Short"]
      ]
    )
    expect(blocks[:spec_stream_writer]).to eq([true, true])
    expect(blocks[:spec_stream_judge]).to eq([false, false])
  end

  it "withdraws a round before_eval rejects as the next begins, and the last round ends in the step's failure alone" do
    agent("SpecScreenedWriter", :spec_stream_writer, [said("One"), said("Two")])
    agent("SpecScreenedJudge", :spec_stream_judge, [verdict(false)])
    screen = ->(state, _context) { state.candidate == "One" ? { accept: false, feedback: "Again" } : nil }

    result = drafting("SpecScreenedOptimize", before_eval: screen).new(context: {}).run!

    expect(sink.calls.map(&:first)).to eq(%i[start delta reset start delta fail])
    expect(result.state).to eq(:failed)
  end

  it "finishes with the last round's text when the step keeps it, never withdrawn first" do
    agent("SpecKeptWriter", :spec_stream_writer, [said("Kept ", "anyway")])
    agent("SpecKeptJudge", :spec_stream_judge, [verdict(false)])

    result = drafting("SpecKeptOptimize", max_rounds: 1, on_exhaustion: :return_last).new(context: {}).run!

    expect(result.output).to eq("Kept anyway")
    expect(sink.calls.map(&:first)).to eq(%i[start delta delta finish])
  end

  it "reports a missing sink, and checks the generator's route" do
    Smith.config.stream_sinks = {}
    agent("SpecUnsunkWriter", :spec_stream_writer, [said("x")])
    agent("SpecUnsunkJudge", :spec_stream_judge, [verdict(true)])

    diagnostics = drafting("SpecUnsunkOptimize").runtime_readiness.runtime_diagnostics
                                                .select { _1.transition == :draft }

    expect(diagnostics.map(&:code)).to include(:stream_sink_missing)
  end

  it "declares the stream as execute does: a Symbol, never with batch mode, shown in the graph" do
    klass = workflow_class
    schema = verdict_schema
    declare = lambda do |**options|
      Class.new(klass) do
        transition(:t, from: :a, to: :b) do
          optimize generator: :w, evaluator: :j, max_rounds: 2, evaluator_schema: schema, **options
        end
      end
    end

    expect { declare.call(stream: "draft") }.to raise_error(Smith::WorkflowError, /optimize stream: must name a sink/)
    expect { declare.call(stream: :draft, mode: :batch) }.to raise_error(Smith::WorkflowError, /cannot stream/)
    expect(declare.call(stream: :draft).graph.transitions.values.sole.stream).to eq(:draft)
  end
end
