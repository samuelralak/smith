# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# A four-component program on request-aware stubs for the tuner's specs
# (slice 5a design, section 5): find, draft, check and answer, each an
# agent whose instructions are a named prompt. The draft's base text is
# weak: the program answers right only when the draft is sent the stub's
# good text (GOOD_DRAFT), so a run that finds it beats the seed. 12
# training and 31 validation samples (tagged train and val, each its own
# cluster); every validation input carries SEALED, a token that must never
# reach a reflection. The scorer's feedback names the expected answer and
# logs each sample it is asked about. The reflection's stub answers the
# good text for the draft and the same text with one more sentence for
# any other component. One host ledger caps the subject and the
# reflection: `admit` (nil for no end) is how many calls it lets through.
# Nothing is sent: unstubbed calls are refused.
RSpec.shared_context "with a tuning run suite" do
  let(:tuning_store) { Smith::Evals::Stores::Memory.new }
  let(:tuning_scope) { { "tenant" => "ten_1" } }
  let(:tuning_key) { "tune-1" }
  let(:tuning_dir) { Dir.mktmpdir("smith-tuning-run") }
  let(:texts) do
    { "find.predict" => "Find what the question asks.", "draft.predict" => "Draft something.",
      "check.predict" => "Check the draft.", "answer.predict" => "Give the final answer." }
  end
  let(:feedback_asked) { Queue.new }
  let(:admit) { nil }
  let(:ledger) { TuningRunSuite::Ledger.new(admit) }
  let(:reflection_setting) do
    { model: "gpt-4.1-mini", provider: :openai, temperature: 1.0, max_output_tokens: 16_384, budget_ledger: ledger }
  end
  let(:reply) do
    lambda do |request|
      message = request.last_user
      component = message[/The step's component: (\S+)/, 1]
      current = TuningRunSuite.current(message)
      instruction = component == "draft.predict" ? TuningRunSuite::GOOD_DRAFT : "#{current} Be careful."
      { idea: "Say what to do for #{component}.", instruction: }
    end
  end

  around do |example|
    unstubbed = Smith::Testing.unstubbed
    key = RubyLLM.config.openai_api_key
    pricing = Smith.config.pricing
    RubyLLM.configure { |config| config.openai_api_key = "test" }
    Smith.config.pricing = { %w[openai gpt-4.1-mini] => { input_cost_per_token: 0.000001,
                                                          output_cost_per_token: 0.000004 } }
    Smith::Testing.unstubbed = :refuse
    example.run
  ensure
    Smith::Testing.unstubbed = unstubbed
    Smith::Testing.reset!
    Smith.config.pricing = pricing
    RubyLLM.configure { |config| config.openai_api_key = key }
    FileUtils.rm_rf(tuning_dir)
  end

  before do
    TuningRunSuite.dataset(tuning_dir)
    TuningRunSuite.define(self, texts, ledger)
    TuningRunSuite.stub_program
    Smith::Testing.stub_agent(Smith::Tuning::Reflection::Runner.agent(reflection_setting),
                              usage: { input_tokens: 400, output_tokens: 60 }, outputs: reply)
  end

  def tuning_suite(**options)
    dir = tuning_dir
    scorer = options.fetch(:scorer) { TuningRunSuite.exact(feedback_asked) }
    with_stubbed_class("SpecTunedSuite", Smith::Evals::Suite) do
      suite_name "spec.tuned_qa"
      dataset dir
      subject workflow: SpecTunedQA, input: ->(sample) { { question: sample.input } }, keep: %i[answer]
      trials 3
      error_retries 0
      concurrency options.fetch(:concurrency, 2)
      scorer scorer
    end
  end

  # Tuning.run's settings as the pilot passes them, with `stop` over a
  # budget of 100 metric calls.
  def tuning_settings(**overrides)
    { objective: :exact, components: texts.keys,
      split: { train: { tags_any: ["train"] }, validation: { tags_any: ["val"] } },
      reflection: reflection_setting, minibatch: 3, seed: 0, skip_perfect: true, perfect_score: 1.0,
      stop: { max_metric_calls: 100, rounds_without_improvement: nil }, scope: tuning_scope,
      idempotency_key: tuning_key, started_by: Smith::Evals::Actor.service("spec"), store: tuning_store }
      .merge(overrides)
  end

  def asked_feedback = Array.new(feedback_asked.size) { feedback_asked.pop }
end

# What the context builds, apart from RSpec's own.
module TuningRunSuite
  GOOD_DRAFT = "Draft the answer the question asks for."
  SEALED = "SEALED"
  AGENTS = { "find.predict" => :spec_tuned_find, "draft.predict" => :spec_tuned_draft,
             "check.predict" => :spec_tuned_check, "answer.predict" => :spec_tuned_answer }.freeze

  # A host budget ledger that admits `admit` calls in all (nil: every one).
  class Ledger
    attr_reader :reserved

    def initialize(admit)
      @admit = admit
      @reserved = 0
      @lock = Mutex.new
    end

    def reserve!(*, **)
      @lock.synchronize do
        next false if @admit && @reserved >= @admit

        @reserved += 1
        true
      end
    end

    def reconcile!(_key, _amount) = nil
    def release!(_key) = nil
  end

  # One field of text, as each step answers.
  class Text
    def to_json_schema
      { name: "text", schema: { type: "object", required: %w[text], additionalProperties: false,
                                properties: { text: { type: "string" } } } }
    end
  end

  module_function

  # The exact match of the kept answer, with feedback naming the expected
  # answer (withheld from the reflection unless the scorer opts in), each
  # sample it is asked about logged to `asked`. Built when first asked, so
  # loading the specs loads no evals.
  def exact(asked)
    Class.new(Smith::Evals::Scorer) do
      scorer_name :exact
      version 1

      def score(sample, trial) = Smith::Evals::Score.match(trial.state.dig(:answer, :text), sample.expected)

      define_method(:feedback) do |sample, trial, component:|
        asked << sample.id
        "#{component}: the answer should be #{sample.expected}, not #{trial.state.dig(:answer, :text).inspect}"
      end
    end
  end

  def ids(prefix, count) = Array.new(count) { format("#{prefix}-%03d", _1) }

  def dataset(dir)
    lines = { "train" => ids("t", 12), "val" => ids("v", 31) }.flat_map do |tag, ids|
      ids.map do |id|
        question = tag == "val" ? "question #{id} #{SEALED}" : "question #{id}"
        { "id" => id, "input" => question, "expected" => "answer #{id}", "tags" => [tag], "cluster" => id }
      end
    end
    File.binwrite(File.join(dir, "samples.jsonl"), lines.map { "#{JSON.generate(_1)}\n" }.join)
    Smith::Evals::Dataset.build_manifest(dir, name: "tuned-qa", holdout: 0.0, calibration: 0.0, seed: "tuned")
  end

  def define(group, texts, ledger)
    AGENTS.each do |component, name|
      built = agent(component, texts.fetch(component))
      group.stub_const("SpecTuned#{name.to_s.split("_").last.capitalize}", built)
      Smith::Agent::Registry.delete(name)
      built.register_as(name)
    end
    group.stub_const("SpecTunedQA", workflow(ledger))
  end

  def agent(component, text)
    prompt = Smith::Prompt.new(component, text)
    Class.new(Smith::Agent) do
      model "gpt-4.1-mini", provider: :openai, assume_model_exists: true
      instructions prompt
      output_schema Text.new
      output_repairs 0
    end
  end

  def workflow(ledger)
    Class.new(Smith::Workflow) do
      budget_ledger { |_scope| ledger }
      initial_state :asked
      %i[found drafted checked answered failed].each { state _1 }
      { find: %i[asked found question], draft: %i[found drafted find], check: %i[drafted checked draft],
        answer: %i[checked answered check] }.each do |step, (from, to, read)|
        transition step, from:, to: do
          input = ->(context) { [{ role: :user, content: TuningRunSuite.text_of(context[read]) }] }
          execute :"spec_tuned_#{step}", input:, output_to: step
          on_failure :fail
        end
      end
    end
  end

  def text_of(value) = value.is_a?(Hash) ? (value[:text] || value["text"]).to_s : value.to_s

  def stub_program
    usage = { input_tokens: 100, output_tokens: 20 }
    AGENTS.each_value { |name| Smith::Testing.stub_agent(name, usage:, outputs: ->(request) { answer(name, request) }) }
  end

  # Each step answers from its own instruction and what it was given: the
  # draft writes the answer only when it is sent the good text.
  def answer(name, request)
    given = request.last_user
    id = given[/[tv]-\d{3}/]
    draft = instruction(request) == GOOD_DRAFT ? "answer #{id}" : "maybe #{id}"
    { text: name == :spec_tuned_draft ? draft : given }
  end

  def instruction(request) = request.messages.find { %w[system developer].include?(_1["role"]) }&.dig("text")

  # Lines with a reflection's steps aside from their times and attempt
  # ids, and the untrusted blocks' boundaries, drawn afresh for each message.
  def steady(lines)
    JSON.parse(JSON.generate(lines).gsub(/boundary=\\"[0-9a-f]+\\"/, "boundary")).map do |line|
      next line unless line["steps"]

      line.merge("steps" => line["steps"].map { _1.except("attempt_id", "offset_ms", "duration_ms") })
    end
  end

  # The current instruction, as the reflection's message wraps it.
  def current(message)
    block = message[%r{The current instruction:\n\n(<untrusted[^>]*>\n?)(.*?)(\n?</untrusted[^>]*>)}m, 2]
    block.to_s.strip
  end
end
