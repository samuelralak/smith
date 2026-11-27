# frozen_string_literal: true

require "smith/evals"
require "smith/testing"

# A host driver runs the subject its own way (another process, another
# library) and records the model calls it made through
# Smith::Evals::Driver#record_step, so each is a step record like Smith's
# own driver's: priced from its tokens, bounded, valid against the trial
# schema, and read by the tuner's check that a changed component was sent.
RSpec.describe Smith::Evals::Driver, "#record_step" do
  include_context "with an eval run suite"

  let(:base) { Smith::Prompt.new("answer.predict", "Answer the ticket.") }
  let(:changed) { Smith::Prompt.new("triage.predict", "Triage the ticket.").with_text("Triage it, in one word.") }
  let(:candidate) do
    reference = { "candidate_id" => format("cd_%032x", 1), "tuning_run_id" => format("tu_%032x", 1),
                  "components" => [{ "id" => changed.component_id, "version" => changed.version }] }
    Struct.new(:reference, :texts).new(reference, { changed.component_id => changed.text })
  end

  # Two calls a trial, each recorded: the first with the candidate's
  # component at the version of the text it sent (or, when the driver
  # drops the candidate, the base text), the second with a base component;
  # the answer it kept is the subject's state.
  let(:sends_candidate) { true }
  let(:driver) do
    calls = [changed, base].map { |prompt| [prompt.component_id, prompt] }
    honest = sends_candidate
    Class.new(described_class) do
      define_method(:run) do |trial, _context|
        calls.each_with_index do |(id, prompt), index|
          text = honest && trial.candidate ? trial.candidate.texts.fetch(id, prompt.text) : prompt.text
          text = "Triage the ticket." if id == "triage.predict" && !honest
          sent = Smith::Prompt.new(id, text)
          record_step(trial, model: "claude-haiku-4-5", provider: :anthropic, tokens: { input: 100, output: 20 },
                             components: [{ id:, version: sent.version }],
                             messages: [{ "role" => "system", "text" => text }, { "role" => "user", "text" => "s" },
                                        { "role" => "assistant", "text" => "billing" }],
                             started: Process.clock_gettime(Process::CLOCK_MONOTONIC), duration_ms: 5 + index)
        end
        SpecHostAnswer
      end
    end.new
  end

  before do
    stub_const("SpecHostAnswer", Smith::Evals::SubjectResult.new(
                                   ended: :terminal, final_state: "done", failed: false, output: nil,
                                   state: { triage: { category: "billing", priority: "low" } }, error: nil,
                                   waiting: nil, usage_entries: [], child_runs: 0, duration_ms: 11
                                 ))
  end

  it "records each call as a step, priced, bounded and valid, the changed component at the candidate's version" do
    klass = suite(trials: 1)
    klass.driver(driver)
    run = run_suite(klass, samples: %w[s-01 s-02], trials: 1, candidate:, kind: :tuning_minibatch)
    lines = run.record.each_trial.to_a
    steps = lines.first["steps"]

    expect(lines.map { _1["outcome"] }).to eq(%w[scored scored])
    expect(steps.map { _1.values_at("seq", "outcome", "model", "provider", "cost_nanos", "cost_known") })
      .to eq([[1, "completed", "claude-haiku-4-5", "anthropic", 200_000, true],
              [2, "completed", "claude-haiku-4-5", "anthropic", 200_000, true]])
    expect(steps.map { _1["components"] })
      .to eq([[{ "id" => changed.component_id, "version" => changed.version }],
              [{ "id" => base.component_id, "version" => base.version }]])
    expect(steps.first["messages"].first).to eq("role" => "system", "text" => changed.text)
    expect(steps.map { _1["sent_count"] }).to eq([2, 2])
    expect(lines.first["usage"].values_at("cost_nanos", "provider_calls", "cost_complete")).to eq([400_000, 2, true])
    expect(lines.flat_map { _1["steps"] }.map { step_errors(_1) }.uniq).to eq([[]])
  end

  # The tuner's seam reads the components of every step: a driver that
  # sends the base text for a component the candidate changed stops the
  # tuning run.
  context "with the tuner's seam" do
    def pass(klass)
      require "smith/tuning"
      triage = Smith::Prompt.new("triage.predict", "Triage the ticket.")
      tuned = Struct.new(:reference, :texts, :versions)
                    .new(candidate.reference, candidate.texts, { "triage.predict" => changed.version })
      seam = Smith::Tuning::Evaluation::InProcess.new(
        suite: klass, scope: eval_scope, store: eval_store, started_by: nil, objective: "category", samples: {},
        train_ids: [], reflection: nil, base_versions: { "triage.predict" => triage.version }
      )
      seam.evaluate(tuned, sample_ids: %w[s-01 s-02], kind: :tuning_validation, key: "host-#{sends_candidate}")
    end

    it "passes the check when the driver sent the candidate's text" do
      klass = suite(trials: 1)
      klass.driver(driver)

      expect(pass(klass).to_h.values_at(:stop, :metric_calls)).to eq([nil, 2])
    end

    context "when the driver sends the base text" do
      let(:sends_candidate) { false }

      it "stops the pass candidate_not_sent" do
        klass = suite(trials: 1)
        klass.driver(driver)

        expect(pass(klass).stop).to eq(:candidate_not_sent)
      end
    end
  end

  # A host driver knows what each call was sent with and which of its
  # parts made it: the step keeps both, as Smith's own driver's do.
  it "keeps the settings and agent a driver gives, and the driver's name and no settings when it gives none" do
    given = Class.new(described_class) do
      def run(trial, _context)
        record_step(trial, model: "claude-haiku-4-5", provider: :anthropic, tokens: { input: 10, output: 2 },
                           agent: "final_answer", settings: { temperature: 1.0, max_output_tokens: 16_384,
                                                              thinking: { effort: "low" } })
        record_step(trial, model: "claude-haiku-4-5", provider: :anthropic, tokens: { input: 10, output: 2 })
        SpecHostAnswer
      end
    end
    stub_const("SpecHostDriver", given)
    klass = suite(trials: 1)
    klass.driver(SpecHostDriver.new)
    steps = run_suite(klass, samples: %w[s-01], trials: 1).record.each_trial.first["steps"]

    expect(steps.map { _1.values_at("agent", "settings") })
      .to eq([["final_answer", { "temperature" => 1.0, "max_output_tokens" => 16_384,
                                 "thinking" => { "effort" => "low" } }],
              ["SpecHostDriver", { "temperature" => nil, "max_output_tokens" => nil, "thinking" => nil }]])
    expect(steps.map { step_errors(_1) }.uniq).to eq([[]])
  end

  it "reads the settings a driver gives by String keys as by Symbol keys" do
    given = Class.new(described_class) do
      def run(trial, _context)
        record_step(trial, model: "claude-haiku-4-5", provider: :anthropic, tokens: { input: 10, output: 2 },
                           settings: { "temperature" => 1.0, "max_output_tokens" => 16_384,
                                       "thinking" => { "effort" => "low" } })
        SpecHostAnswer
      end
    end
    klass = suite(trials: 1)
    klass.driver(given.new)
    step = run_suite(klass, samples: %w[s-01], trials: 1).record.each_trial.first["steps"].first

    expect(step["settings"]).to eq("temperature" => 1.0, "max_output_tokens" => 16_384,
                                   "thinking" => { "effort" => "low" })
    expect(step_errors(step)).to eq([])
  end

  # A trial a host driver could not run is no failed answer: raising the
  # ledger's refusal stops the run incomplete, raising HostUnavailable (a
  # lost worker, a host service down) stops it failed; either trial is
  # not_run, no line, and the run, called again, runs it.
  {
    Smith::BudgetUnavailable => [:incomplete, "ledger_refused"],
    Smith::Evals::HostUnavailable => [:failed, "host_unavailable"]
  }.each do |error, (status, code)|
    it "stops the run #{status} when the driver raises #{error.name.split("::").last}, and goes on when called again" do
      stub_const("SpecHostDown", [true])
      raising = Class.new(described_class) do
        define_method(:run) do |trial, _context|
          raise error, "the host could not run it" if SpecHostDown.first && trial.sample.id == "s-03"

          SpecHostAnswer
        end
      end
      klass = suite(trials: 1)
      klass.driver(raising.new)
      stopped = run_suite(klass)
      ran = stopped.record.each_trial.map { _1["sample_id"] }
      SpecHostDown[0] = false
      finished = run_suite(klass)

      expect([stopped.status, stopped.summary.dig("stop", "reason").values_at("code", "by")])
        .to eq([status, [code, "infrastructure"]])
      expect(ran).to eq(%w[s-01 s-02])
      expect([finished.status, finished.record.each_trial.count]).to eq([:succeeded, 12])
    end
  end

  it "records nothing outside a trial's run" do
    trial = Smith::Evals::TrialSpec.for(eval_run_id: format("er_%032x", 9), scope: eval_scope,
                                        sample: Smith::Evals::Sample.new({ "id" => "x", "input" => "y" }, split: :dev),
                                        trial_index: 0, subject: nil)

    expect(driver.record_step(trial, model: "m", provider: :openai)).to be_nil
  end

  def step_errors(step)
    %i[open strict].flat_map do |mode|
      EvalsSchema.errors(step, schema: "trial", strict: mode == :strict, pointer: "#/$defs/step")
    end
  end
end
