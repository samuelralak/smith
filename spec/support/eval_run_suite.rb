# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# A 12-sample suite on request-aware stubs for the runner's specs (slice-1a
# design, 12.1): three trials a sample; s-03 always answered wrong, s-04
# never in the answer's format (a failed subject), s-05 right only after an
# output repair, s-12 with no expected priority (its priority scorer cannot
# decide). Each attempt begins with a step that logs its trial (`started`),
# calls `hook` and, for a trial `faults` names, meets the host's own
# infrastructure error (SpecEvalHostDown) on its first attempts, by trial
# id, so a retry lands on the same trial however trials interleave. Nothing
# is sent: unstubbed calls are refused.
RSpec.shared_context "with an eval run suite" do
  let(:eval_store) { Smith::Evals::Stores::Memory.new }
  let(:eval_scope) { { "tenant" => "ten_1" } }
  let(:eval_key) { "e2e-1" }
  let(:faults) { {} }
  let(:fault_calls) { Hash.new(0) }
  let(:fault_lock) { Mutex.new }
  # Each attempt's trial id, in the order the attempts began.
  let(:started) { [] }
  # Called with the trial id as each attempt begins, before any fault.
  let(:hook) { ->(_trial) {} }
  let(:dataset_dir) { Dir.mktmpdir }

  around do |example|
    unstubbed = Smith::Testing.unstubbed
    key = RubyLLM.config.anthropic_api_key
    pricing = Smith.config.pricing
    RubyLLM.configure { |config| config.anthropic_api_key = "test" }
    prices = { input_cost_per_token: 0.000001, output_cost_per_token: 0.000005 }
    # The alias, and the dated id the provider gem resolves it to.
    Smith.config.pricing = { %w[anthropic claude-haiku-4-5] => prices,
                             %w[anthropic claude-haiku-4-5-20251001] => prices }
    Smith::Testing.unstubbed = :refuse
    example.run
  ensure
    Smith::Testing.unstubbed = unstubbed
    Smith::Testing.reset!
    Smith.config.pricing = pricing
    RubyLLM.configure { |config| config.anthropic_api_key = key }
    FileUtils.rm_rf(dataset_dir)
  end

  before do
    stub_const("SpecEvalHostDown", Class.new(StandardError))
    write_dataset
    define_agent
    define_workflow
    Smith::Testing.stub_agent(:spec_eval_classifier, usage: { input_tokens: 100, output_tokens: 20 },
                                                     outputs: method(:answer))
  end

  def categories = %w[billing shipping account technical other]

  def write_dataset
    lines = (1..12).map { "#{JSON.generate(sample_line(_1))}\n" }
    File.write(File.join(dataset_dir, "samples.jsonl"), lines.join)
    Smith::Evals::Dataset.build_manifest(dataset_dir, name: "e2e-tickets", holdout: 0.0, calibration: 0.0,
                                                      seed: "e2e")
  end

  def sample_line(number)
    id = format("s-%02d", number)
    expected = { "category" => categories[number % 5], "priority" => number.even? ? "urgent" : "low" }
    expected.delete("priority") if id == "s-12"
    { "id" => id, "input" => { "text" => "Ticket #{id}: please help." }, "expected" => expected,
      "cluster" => "cus-#{(number + 1) / 2}" }
  end

  def define_agent
    schema = Class.new do
      def to_json_schema
        { name: "triage", schema: { type: "object", required: %w[category priority],
                                    properties: { category: { type: "string" }, priority: { type: "string" } } } }
      end
    end
    stub_const("SpecEvalSchema", schema)
    with_stubbed_class("SpecEvalClassifier", Smith::Agent) do
      register_as :spec_eval_classifier
      model "claude-haiku-4-5", provider: :anthropic
      instructions { "Sort the ticket. Answer JSON: category and priority." }
      output_schema SpecEvalSchema
    end
  end

  def define_workflow
    fault = method(:fault!)
    with_stubbed_class("SpecEvalTriage", Smith::Workflow) do
      initial_state :new
      %i[checked triaged failed].each { state _1 }
      seed_messages { |context| [{ role: :user, content: context[:ticket] }] }
      transition(:check, from: :new, to: :checked) do
        compute { |_step| fault.call }
        on_failure :fail
      end
      transition :classify, from: :checked, to: :triaged do
        execute :spec_eval_classifier, output_to: :triage
        on_failure :fail
      end
    end
  end

  # The host's own error on a faulted trial's first attempts.
  def fault!
    trial = Smith::Attribution.current.trial
    count = fault_lock.synchronize do
      started << trial
      fault_calls[trial] += 1
    end
    hook.call(trial)
    raise SpecEvalHostDown, "the host's database is down" if count <= faults.fetch(trial, 0)
  end

  # The answer to a request, from its ticket alone (and whether it is the
  # output repair's request).
  def answer(request)
    ticket = request.messages.find { _1["role"] == "user" }["text"]
    id = ticket[/s-\d\d/]
    return "Category: billing." if id == "s-04" || (id == "s-05" && request.last_user == ticket)

    number = id[2, 2].to_i
    { category: id == "s-03" ? "other" : categories[number % 5], priority: number.even? ? "urgent" : "low" }
  end

  def suite(name = "SpecEvalSuite", concurrency: 1, **options)
    dir = dataset_dir
    klass = with_stubbed_class(name, Smith::Evals::Suite) do
      suite_name options.fetch(:suite_name, "spec.e2e_triage")
      dataset dir
      trials options.fetch(:trials, 3), reduce: :majority
      concurrency concurrency
      infrastructure_errors SpecEvalHostDown
      recording content: options.fetch(:content, true)
    end
    subject_of(klass, options)
    scorers(klass, options.fetch(:priority_version, 1))
  end

  def subject_of(klass, options)
    klass.subject workflow: options.fetch(:workflow) { SpecEvalTriage },
                  input: options.fetch(:input) { ->(sample) { { ticket: sample.input[:text] } } },
                  keep: options.fetch(:keep, %i[triage]), until: options[:until]
  end

  # category (binary, with the mean too), priority (binary; it cannot
  # decide without an expected priority) and tone (continuous).
  def scorers(klass, priority_version)
    klass.scorer(:category, version: 1, also: [:mean], &method(:category_score))
    klass.scorer(:priority, version: priority_version, &method(:priority_score))
    klass.scorer(:tone, version: 1, scale: :continuous, &method(:tone_score))
    klass
  end

  def category_score(sample, trial)
    Smith::Evals::Score.match(trial.state.dig(:triage, :category), sample.expected[:category])
  end

  def priority_score(sample, trial)
    return Smith::Evals::Score.unscored("the sample has no expected priority") unless sample.expected[:priority]

    Smith::Evals::Score.match(trial.state.dig(:triage, :priority), sample.expected[:priority])
  end

  def tone_score(_sample, trial) = Smith::Evals::Score.value(trial.state.dig(:triage, :priority) == "urgent" ? 1 : 0.25)

  def trial_id(sample_id, index, key: eval_key, suite_name: "spec.e2e_triage")
    run = Smith::Evals::Identity.eval_run_id(key:, scope: eval_scope, suite: suite_name)
    Smith::Evals::Identity.trial_id(eval_run_id: run, sample_id:, index:)
  end

  def run_suite(klass, store: eval_store, **)
    Smith::Evals.run(klass, scope: eval_scope, idempotency_key: eval_key, store:, **)
  end

  def record_of(run, store: eval_store)
    [store.read_header(scope: eval_scope, eval_run_id: run.eval_run_id),
     store.each_segment(scope: eval_scope, eval_run_id: run.eval_run_id).to_a,
     store.each_trial(scope: eval_scope, eval_run_id: run.eval_run_id).to_a,
     store.read_summary(scope: eval_scope, eval_run_id: run.eval_run_id)]
  end

  # What another trial hands over, or a failure after 10 seconds, so a
  # spec whose trials wait on each other fails rather than hangs.
  def waited(queue) = queue.pop(timeout: 10) || raise("waited 10 seconds for another trial")

  def schema_errors(document, schema)
    %i[open strict].flat_map { |mode| EvalsSchema.errors(document, schema:, strict: mode == :strict) }
  end
end
