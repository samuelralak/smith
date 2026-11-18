# frozen_string_literal: true

require "json"
require "smith/testing/rspec"

# What an optimize round's tools stage is the host's to set aside:
# `before_generate` runs before each round's generator is asked, the first
# round of every attempt included, when everything the step's tools did
# belongs to a round the loop rejected or an attempt that failed; and every
# capture a round takes names that round.
RSpec.describe "Smith optimize before_generate" do
  include_context "with a recording budget ledger"

  let(:testing) { Smith::Testing }
  let(:staged) { [] }
  let(:verdict_schema) do
    Class.new do
      def to_json_schema
        { name: "verdict", schema: { type: "object", required: %w[accept feedback],
                                     properties: { accept: { type: "boolean" }, feedback: { type: "string" } } } }
      end
    end
  end

  # A write that stages its value, as a host's pending row, and captures it.
  def staging
    rows = staged
    stub_const("SpecStageValue", Class.new(Smith::Tool) do
      description "Stage a value."
      param :value, type: :string, required: true
      capabilities { replay :safe }
      capture_result(strict: true) { |kwargs, _result| { value: kwargs[:value] } }
      define_method(:perform) { |value:| (rows << value) && "staged #{value}" }
    end)
  end

  # The evaluator, answered over the wire: each verdict, or a provider outage.
  def judge(verdicts)
    agent("SpecStageJudge", register: :spec_stage_judge)
    verdicts.each_with_index do |verdict, index|
      if verdict == :outage
        server.reply(json: { type: "error", error: { type: "api_error", message: "down" } }, status: "500 Server Error")
      else
        server.reply(json: message(JSON.generate(verdict), id: "msg_verdict_#{index}"))
      end
    end
  end

  def drafting(name, retried: false, **optimize)
    schema = verdict_schema
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "write a line" }] }
      transition :draft, from: :idle, to: :done do
        optimize generator: :spec_stage_writer, evaluator: :spec_stage_judge, max_rounds: 3,
                 evaluator_schema: schema, output_to: :draft, **optimize
        retry_on Smith::AgentError, attempts: 2, backoff: 0 if retried
        on_failure :fail
      end
    end
  end

  def writes(*values)
    tool = staging
    agent("SpecStageWriter", register: :spec_stage_writer) { tools tool }
    outputs = values.flat_map { [testing.tool_call(tool, value: _1), "#{_1} line"] }
    testing.stub_agent(:spec_stage_writer, outputs:)
  end

  def rejected(feedback) = { accept: false, feedback: }
  def accepted = { accept: true, feedback: "ok" }

  it "runs before each round's generator, with the round under way, and each capture names its round" do
    writes("one", "two")
    judge([rejected("again"), accepted])
    seen = []
    before_generate = ->(state, context) { seen << [state.round, staged.dup, context[:topic]] }

    result = drafting("SpecStageRoundsWorkflow", before_generate:).new(context: { topic: "gym" }).run!

    expect([result.state, result.context[:draft]]).to eq([:done, "two line"])
    expect(seen).to eq([[0, [], "gym"], [1, ["one"], "gym"]])
    expect(result.tool_results.map { [_1[:captured][:value], _1[:round]] }).to eq([["one", 0], ["two", 1]])
  end

  it "lets a host set aside what a rejected round staged before the next round writes" do
    writes("one", "two")
    judge([rejected("again"), accepted])

    result = drafting("SpecStageSetAsideWorkflow", before_generate: ->(_state, _context) { staged.clear })
             .new(context: {}).run!

    expect([result.state, staged]).to eq([:done, ["two"]])
  end

  it "tells a later round's generator what it says the rejected round left, after the feedback" do
    writer = writes("one", "two")
    judge([rejected("again"), accepted])
    before_generate = lambda do |state, _context|
      { rejected_round: "You staged #{staged.join(", ")}." } if state.round.positive?
    end

    result = drafting("SpecStageNoteWorkflow", before_generate:).new(context: {}).run!
    refining = writer.calls.find { |messages| messages.last.content.to_s.start_with?("[smith:refinement-round]") }

    expect(result.state).to eq(:done)
    expect(refining.last.content.to_s)
      .to eq("[smith:refinement-round] 2\n[smith:evaluator-feedback]\nagain\n[smith:rejected-round]\nYou staged one.")
  end

  it "tells a later round nothing more for a bare String, blank words or anything but rejected_round" do
    [->(_state, _context) { "You staged one." }, ->(_state, _context) { { rejected_round: "  " } },
     ->(_state, _context) { staged.dup }].each_with_index do |before_generate, index|
      staged.clear
      writer = writes("one", "two")
      judge([rejected("again"), accepted])

      drafting("SpecStageQuietWorkflow#{index}", before_generate:).new(context: {}).run!
      refining = writer.calls.find { |messages| messages.last.content.to_s.start_with?("[smith:refinement-round]") }

      expect(refining.last.content.to_s).to eq("[smith:refinement-round] 2\n[smith:evaluator-feedback]\nagain")
    end
  end

  it "fails the step when rejected_round is not a String" do
    writes("one", "two")
    judge([rejected("again"), accepted])

    result = drafting("SpecStageBadNoteWorkflow", before_generate: ->(_state, _context) { { rejected_round: 1 } })
             .new(context: {}).run!

    expect([result.state, result.last_error.message])
      .to eq([:failed, "before_generate's rejected_round must be a String"])
  end

  it "runs before a retried attempt's first round, whose captures alone remain" do
    writes("one", "two")
    judge([:outage, accepted])
    seen = []

    before_generate = ->(state, _context) { seen << [state.round, staged.dup] }

    result = drafting("SpecStageRetryWorkflow", retried: true, before_generate:).new(context: {}).run!

    expect(result.state).to eq(:done)
    expect(seen).to eq([[0, []], [0, ["one"]]])
    expect(result.tool_results.map { [_1[:captured][:value], _1[:round]] }).to eq([["two", 0]])
    expect(result.evaluations.map { _1.values_at(:attempt, :round) }).to eq([[2, 0]])
  end

  it "fails the step when it raises, before the round's generator is asked" do
    writes("one")
    judge([accepted])

    result = drafting("SpecStageRaiseWorkflow", before_generate: ->(_state, _context) { raise "staging is down" })
             .new(context: {}).run!

    expect([result.state, result.last_error.message, staged]).to eq([:failed, "staging is down", []])
  end

  it "leaves a capture outside an optimize round without one" do
    tool = staging
    agent("SpecStagePlainWriter") { tools tool }
    testing.stub_agent(:spec_ledger_agent, outputs: [testing.tool_call(tool, value: "plain"), "done"])

    result = asking("SpecStagePlainWorkflow").new(context: {}).run!

    expect(result.tool_results.sole).to include(tool: "spec_stage_value", captured: { value: "plain" })
    expect(result.tool_results.sole).not_to have_key(:round)
  end

  describe "a round's captures, its writer answered over the wire" do
    let(:adapter) { Smith::PersistenceAdapters::Memory.new }

    def calling(tool, *values, id:)
      content = values.each_with_index.flat_map do |value, index|
        tool_use(tool.new.name, id: values.one? ? id : "#{id}_#{index}", input: { "value" => value })
      end
      { json: message(nil, id: "msg_#{id}", stop: "tool_use", tokens: [10, 4], content:) }
    end

    def replies(*replies) = replies.each { server.reply(**_1) }
    def line(text) = { json: message(text, id: "msg_#{text.tr(" ", "_")}") }
    def verdict(accept) = { json: message(JSON.generate(accept:, feedback: "again"), id: "msg_verdict_#{accept}") }

    def captures(result) = result.tool_results.map { _1.slice(:tool_call_id, :round) }

    it "names the round on the captures of concurrent tool calls" do
      tool = staging
      agent("SpecStageConcurrentWriter", register: :spec_stage_writer) { tools tool }
      agent("SpecStageConcurrentJudge", register: :spec_stage_judge)
      replies(calling(tool, "one", "two", id: "toolu_c"), line("both"), verdict(true))
      RubyLLM.config.tool_concurrency = :threads

      result = drafting("SpecStageConcurrentWorkflow").new(context: {}).run!

      expect(result.state).to eq(:done)
      expect(captures(result)).to contain_exactly({ tool_call_id: "toolu_c_0", round: 0 },
                                                  { tool_call_id: "toolu_c_1", round: 0 })
    ensure
      RubyLLM.config.tool_concurrency = nil
    end

    it "keeps a provider attempt set aside inside a round out, the kept captures naming the round" do
      tool = staging
      down = { json: { type: "error", error: { type: "api_error", message: "down" } }, status: "500 Server Error" }
      agent("SpecStageFallbackWriter", register: :spec_stage_writer) do
        tools tool
        fallback_models model: "claude-haiku-5-5", provider: :anthropic
      end
      agent("SpecStageFallbackJudge", register: :spec_stage_judge)
      replies(calling(tool, "one", id: "toolu_a"), down,
              calling(tool, "two", id: "toolu_b"), line("two"), verdict(true))

      result = drafting("SpecStageFallbackWorkflow").new(context: {}).run!

      expect(result.state).to eq(:done)
      expect(captures(result)).to eq([{ tool_call_id: "toolu_b", round: 0 }])
    end

    it "keeps each capture's round through a persisted run's restore" do
      tool = staging
      agent("SpecStagePersistedWriter", register: :spec_stage_writer) { tools tool }
      agent("SpecStagePersistedJudge", register: :spec_stage_judge)
      replies(calling(tool, "one", id: "toolu_p"), line("one"), verdict(false),
              calling(tool, "two", id: "toolu_q"), line("two"), verdict(true))
      klass = drafting("SpecStagePersistedWorkflow")

      klass.new(context: {}).run_persisted!("stage:persisted", adapter:)
      restored = klass.restore("stage:persisted", adapter:)

      expect(restored.to_state[:tool_results].map { _1.slice(:tool_call_id, :round) })
        .to eq([{ tool_call_id: "toolu_p", round: 0 }, { tool_call_id: "toolu_q", round: 1 }])
    end
  end

  it "refuses a before_generate that cannot be called when the workflow loads" do
    expect { drafting("SpecStageBadWorkflow", before_generate: "not callable") }
      .to raise_error(Smith::WorkflowError, /optimize before_generate must respond to :call/)
  end
end
