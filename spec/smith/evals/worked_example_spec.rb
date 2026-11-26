# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "smith/evals"
require "smith/testing"

# The worked example of slice-1a design 4.10, as written there (its classes
# named for the example only): a ticket triage suite on request-aware
# stubs, nothing sent. script/evals_probe runs the same in a fresh process.
RSpec.describe "The worked example" do
  around do |example|
    unstubbed = Smith::Testing.unstubbed
    key = RubyLLM.config.anthropic_api_key
    RubyLLM.configure { |config| config.anthropic_api_key = "test" } # any key; the chat is built, nothing is sent
    Smith::Testing.unstubbed = :refuse
    example.run
  ensure
    Smith::Testing.unstubbed = unstubbed
    Smith::Testing.reset!
    RubyLLM.configure { |config| config.anthropic_api_key = key }
  end

  let(:demo_dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(demo_dir) }

  before do
    with_stubbed_class("TriageSchema") do
      def to_json_schema
        { name: "triage", schema: { type: "object", required: %w[category priority],
                                    properties: { category: { type: "string" }, priority: { type: "string" } } } }
      end
    end
    with_stubbed_class("TicketClassifier", Smith::Agent) do
      register_as :ticket_classifier
      model "claude-haiku-4-5", provider: :anthropic
      instructions { "Sort the support ticket. Answer JSON: category and priority." }
      output_schema TriageSchema
    end
    with_stubbed_class("TicketTriage", Smith::Workflow) do
      initial_state :new
      state :triaged
      state :failed
      seed_messages { |context| [{ role: :user, content: "Channel: #{context[:channel]}\n\n#{context[:ticket]}" }] }

      transition :classify, from: :new, to: :triaged do
        execute :ticket_classifier, output_to: :triage
        on_failure :fail
      end
    end

    File.write(File.join(demo_dir, "samples.jsonl"), <<~JSONL)
      {"id":"t-1","input":{"channel":"email","text":"I was charged twice for order 5521."},"expected":{"category":"billing","priority":"normal"},"cluster":"cus-1"}
      {"id":"t-2","input":{"channel":"chat","text":"My parcel shows delivered but never arrived."},"expected":{"category":"shipping","priority":"urgent"},"cluster":"cus-2"}
      {"id":"t-3","input":{"channel":"email","text":"How do I change my email address?"},"expected":{"category":"account","priority":"low"},"cluster":"cus-3"}
    JSONL
    Smith::Evals::Dataset.build_manifest(demo_dir, name: "tickets-demo", holdout: 0.0, calibration: 0.0, seed: "demo")

    dir = demo_dir
    with_stubbed_class("DemoSuite", Smith::Evals::Suite) do
      suite_name "demo.ticket_triage"
      dataset dir
      subject workflow: TicketTriage, input: ->(s) { { ticket: s.input[:text], channel: s.input[:channel] } },
              keep: %i[triage]
      trials 3, reduce: :majority
      scorer(:category, version: 1) { |s, t| Smith::Evals::Score.match(t.state.dig(:triage, :category), s.expected[:category]) }
      scorer(:priority, version: 1) { |s, t| Smith::Evals::Score.match(t.state.dig(:triage, :priority), s.expected[:priority]) }
    end

    # The stub answers by the ticket, so every trial of a sample gets the
    # same answer whatever order trials run in.
    answers = {
      "charged twice" => { category: "billing", priority: "normal" },
      "never arrived" => { category: "shipping", priority: "normal" }, # priority wrong on purpose
      "email address" => { category: "account", priority: "low" }
    }
    Smith::Testing.stub_agent(TicketClassifier, outputs: lambda { |request|
      answers.find { |needle, _| request.last_user.include?(needle) }&.last || { category: "other", priority: "low" }
    })
  end

  it "runs the ticket triage suite on request-aware stubs to succeeded, with the expected outcomes and results" do
    run = Smith::Evals.run(DemoSuite, store: Smith::Evals::Stores::Memory.new)

    expect(run.status).to eq(:succeeded)
    expect(run.summary["outcomes"]).to eq("scored" => 9, "subject_failed" => 0, "limit_hit" => 0, "unscored" => 0,
                                          "error" => 0, "not_run" => 0)
    category = run.result(:category)
    expect(category).to be_a(Smith::Evals::Statistics::Estimate)
    expect(category.point).to eq(1.0)
    expect(category.method_name).to eq("wilson")
    expect(category.design_effect).to be_nil
    # Wilson's lower bound for 3 of 3 at 95%: 1 / (1 + z**2 / 3), 0.43850... (design 4.10).
    expect(category.lower).to be_within(1e-12).of(1 / (1 + ((1.959963984540054**2) / 3)))
    expect(category.upper).to eq(1.0)
    expect(category.warnings).to eq(["small_sample"])
    expect(category.display).to eq("unit" => "percent", "decimals" => 0, "point" => "100", "lower" => "44",
                                   "upper" => "100")
    expect(run.result(:priority).point).to eq(2.0 / 3)
    first = run.record.each_trial.first
    expect(first["sample_id"]).to eq("t-1")
    expect(first["steps"].first["messages"].map { _1["role"] }).to eq(%w[system user assistant])
    expect(first["steps"].first["messages"].last["json"]).to eq("category" => "billing", "priority" => "normal")
  end
end
