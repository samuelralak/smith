# frozen_string_literal: true

require "smith/tuning"
require "smith/testing"

# A program that is no Smith workflow, run by a host driver (another
# library's program, say): the driver declares the components it tunes and
# their base texts (Smith::Evals::Driver#components), sends a candidate's
# texts in their place, and records its calls (#record_step). The tuner
# reads the base texts through the driver and improves the planted weak
# draft end to end, on stubs.
RSpec.describe Smith::Evals::Driver, "#components, tuned" do
  include_context "with a tuning run suite"

  # Each call of the four parts recorded with the version of the text it
  # sent; the draft answers right only when sent the good text.
  let(:host_driver) do
    base = texts
    Class.new(described_class) do
      define_method(:components) { |_subject| base }
      define_method(:run) do |trial, _context|
        sent = base.merge(trial.candidate&.texts || {})
        sent.each do |id, text|
          record_step(trial, model: "gpt-4.1-mini", provider: :openai, tokens: { input: 100, output: 20 }, agent: id,
                             components: [{ id:, version: Smith::Prompt.new(id, text).version }],
                             messages: [{ "role" => "system", "text" => text },
                                        { "role" => "user", "text" => trial.sample.input },
                                        { "role" => "assistant", "text" => "noted" }])
        end
        answer = sent["draft.predict"] == TuningRunSuite::GOOD_DRAFT ? "answer #{trial.sample.id}" : "maybe"
        Smith::Evals::SubjectResult.new(ended: :terminal, final_state: "done", failed: false, output: nil,
                                        state: { answer: { text: answer } }, error: nil, waiting: nil,
                                        usage_entries: [], child_runs: 0, duration_ms: 1)
      end
    end
  end

  def host_suite
    dir = tuning_dir
    stub_const("SpecHostProgram", Class.new)
    klass = with_stubbed_class("SpecHostSuite", Smith::Evals::Suite) do
      suite_name "spec.host_qa"
      dataset dir
      subject workflow: SpecHostProgram, input: ->(sample) { { question: sample.input } }, keep: %i[answer]
      error_retries 0
    end
    hosted(klass)
  end

  def hosted(klass)
    klass.trials(1)
    klass.concurrency(2)
    klass.scorer(TuningRunSuite.exact(feedback_asked))
    klass.driver(host_driver.new)
    klass
  end

  it "tunes a program that is no workflow, its base texts the driver's, to the planted good draft" do
    record = Smith::Tuning.run(host_suite, **tuning_settings)

    expect(record.header["components"].map { _1.values_at("id", "base_text", "base_version") })
      .to eq(texts.map { |id, text| [id, text, Smith::Prompt.new(id, text).version] })
    expect(record.summary.values_at("status", "ended")).to eq(%w[finished proposal])
    expect(record.best.texts["draft.predict"]).to eq(TuningRunSuite::GOOD_DRAFT)
  end

  it "declares by default the named prompts of a workflow subject, and none of anything else" do
    workflow = Smith::Evals::Subject.new(workflow: SpecTunedQA)

    expect(described_class.new.components(workflow)).to eq(texts)
    expect(described_class.new.components(Smith::Evals::Subject.new(workflow: Class.new))).to eq({})
  end
end
