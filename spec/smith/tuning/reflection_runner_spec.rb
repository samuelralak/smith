# frozen_string_literal: true

require "smith/tuning"
require "smith/testing"

# An iteration's reflection call (slice 5a design, section 1, row 5): one
# call of a one-step Smith workflow whose agent is built from the run's
# `reflection:` setting, run through the in-process driver as a recorded
# trial, so it is a step record of the trial schema's shape, metered and
# capped like any call, with Smith's named prompt as its instructions. An
# error the eval runner retries is tried again, up to the setting's
# attempts (one by default), after the runner's backoff.
RSpec.describe Smith::Tuning::Reflection::Runner do
  include_context "with a tuning run suite"

  let(:model) { Smith::Tuning::Settings::ReflectionModel.build(reflection_setting) }
  let(:trial_id) { Smith::Evals::Identity.reflection_trial_id(tuning_run_id: format("tu_%032x", 3), iteration: 1) }
  let(:message) { "The step's component: draft.predict\n\nThe current instruction:\n\n#{"x" * 70_000}" }

  def runner = described_class.new(model, scope: tuning_scope)

  it "makes the call as a recorded trial: Smith's prompt, its version stamped, the message whole, the reply read" do
    call = runner.call(message, trial_id:)
    prompt = Smith::Tuning::Reflection::PROMPT

    expect(call.trial_id).to eq(trial_id)
    expect([call.failure, call.stop]).to eq([nil, nil])
    expect(call.output.transform_keys(&:to_s)).to eq("idea" => "Say what to do for draft.predict.",
                                                     "instruction" => TuningRunSuite::GOOD_DRAFT)
    step = call.steps.sole
    expect(step["components"]).to eq([{ "id" => prompt.component_id, "version" => prompt.version }])
    expect(step["messages"].first(2)).to eq([{ "role" => "system", "text" => prompt.text },
                                             { "role" => "user", "text" => message }])
    expect(step.values_at("outcome", "model", "provider", "cost_nanos", "cost_known"))
      .to eq(["completed", "gpt-4.1-mini", "openai", 640_000, true])
    expect(call.usage.values_at("provider_calls", "cost_nanos", "cost_complete")).to eq([1, 640_000, true])
    line = Smith::Tuning::Record.reflection(tuning_run_id: format("tu_%032x", 3), iteration: 1, call:)
    expect(%i[open strict].map { EvalsSchema.errors(line, schema: "tuning-line", strict: _1 == :strict) })
      .to eq([[], []])
  end

  it "builds one agent for each reflection model and settings, named for them, its replies held to one call" do
    agent = described_class.agent(reflection_setting)

    expect(described_class.agent(reflection_setting.merge(budget_ledger: nil))).to equal(agent)
    expect(described_class.agent(reflection_setting.merge(temperature: 0.5))).not_to equal(agent)
    expect(described_class.agent(reflection_setting.merge(attempts: 6))).to equal(agent)
    expect(agent.chat_kwargs.slice(:model, :provider)).to eq(model: "gpt-4.1-mini", provider: :openai)
    expect(agent.output_repairs).to eq(0)
    expect(agent.smith_prompt).to equal(Smith::Tuning::Reflection::PROMPT)
  end

  context "when the ledger refuses it" do
    let(:admit) { 0 }

    it "stops the tuning run at the cap, with a failure and no reply" do
      call = runner.call(message, trial_id:)

      expect([call.output, call.stop, call.failure["kind"]]).to eq([nil, :cap_reached, "ledger_refused"])
    end
  end

  # Only a provider that was unavailable is tried again: an error of any
  # other kind, a reply that does not fit among them, ends the call.
  context "when the model fails, or replies with what does not fit" do
    let(:reflection_setting) { super().merge(attempts: 3) }
    let(:reply) { ->(_request) { raise Smith::AgentError, "the model broke" } }

    it "ends only its iteration after one attempt: a failure naming its class, never the error's words, no stop" do
      call = runner.call(message, trial_id:)

      expect([call.output, call.stop]).to eq([nil, nil])
      expect(call.failure.values_at("kind", "error_class")).to eq(%w[agent_error Smith::AgentError])
      expect(call.failure["message"]).not_to include("the model broke")
      expect(call.steps.size).to eq(1)
    end

    it "tries a reply that does not fit no more than once" do
      Smith::Testing.stub_agent(described_class.agent(reflection_setting), outputs: ->(_request) { "not json" })

      call = runner.call(message, trial_id:)

      expect([call.output, call.stop, call.steps.size]).to eq([nil, nil, 1])
      expect(call.failure["kind"]).to start_with("output_")
    end
  end

  # An overloaded provider goes again while attempts are left, after the
  # eval runner's backoff: min(30, 2**attempt) seconds, or none with the
  # driver's retry_waits :immediate (Smith::Testing's).
  context "with three attempts and a provider overloaded at first" do
    let(:reflection_setting) { super().merge(attempts: 3) }
    let(:failures) { 2 }
    let(:reply) do
      answer = super()
      calls = 0
      overloaded = RubyLLM::OverloadedError.new(nil, "Overloaded")
      ->(request) { (calls += 1) <= failures ? raise(overloaded) : answer.call(request) }
    end

    it "tries again after the runner's backoff, each attempt a step the ledger meters, and reads the reply" do
      allow_any_instance_of(Smith::Evals::Drivers::InProcess).to receive(:retry_waits).and_return(:sleep)
      reflection = runner
      allow(reflection).to receive(:sleep)

      call = reflection.call(message, trial_id:)

      expect([call.failure, call.stop]).to eq([nil, nil])
      expect(call.output.transform_keys(&:to_s)).to include("instruction" => TuningRunSuite::GOOD_DRAFT)
      expect(call.steps.map { _1.dig("failure", "kind") }).to eq(["transient", "transient", nil])
      expect(call.steps.map { _1["seq"] }).to eq([1, 2, 3])
      expect(call.usage.values_at("provider_calls", "cost_nanos", "cost_complete")).to eq([3, 640_000, true])
      expect(ledger.reserved).to eq(3)
      expect(reflection).to have_received(:sleep).with(2).ordered
      expect(reflection).to have_received(:sleep).with(4).ordered
    end

    context "when it is overloaded on every attempt" do
      let(:failures) { 3 }

      it "ends only its iteration, every attempt recorded, waiting for none under Smith::Testing" do
        reflection = runner
        allow(reflection).to receive(:sleep)

        call = reflection.call(message, trial_id:)

        expect([call.output, call.stop, call.failure["kind"]]).to eq([nil, nil, "provider_unavailable"])
        expect(call.steps.size).to eq(3)
        expect(ledger.reserved).to eq(3)
        expect(reflection).not_to have_received(:sleep)
      end
    end

    context "when the ledger refuses its second attempt" do
      let(:failures) { 1 }
      let(:admit) { 1 }

      it "stops the tuning run at the cap, asking no third attempt, the refused attempt costing a known 0" do
        call = runner.call(message, trial_id:)

        expect([call.output, call.stop, call.failure["kind"]]).to eq([nil, :cap_reached, "ledger_refused"])
        expect(call.steps.map { _1.dig("failure", "error_class") })
          .to eq(%w[RubyLLM::OverloadedError Smith::BudgetUnavailable])
        expect(call.usage.values_at("provider_calls", "cost_nanos", "cost_complete")).to eq([1, 0, true])
      end
    end
  end
end

# The reflection's request on the wire, through a local server answering as
# Anthropic: the model, temperature and output limit it was given, no
# thinking unless set (the pilot's rule for reflection calls), and a
# provider's overload tried again.
RSpec.describe Smith::Tuning::Reflection::Runner, "on the wire" do
  include_context "with a recording budget ledger"

  let(:reply) { '{"idea":"Shorter.","instruction":"Answer in a phrase."}' }

  def reflect(setting, iteration: 2)
    trial_id = Smith::Evals::Identity.reflection_trial_id(tuning_run_id: format("tu_%032x", 4), iteration:)
    described_class.new(Smith::Tuning::Settings::ReflectionModel.build(setting), scope: {})
                   .call("The step's component: a.b", trial_id:)
  end

  it "sends the model, temperature and output limit of its setting, and no thinking" do
    setting = { model: "claude-haiku-4-5", provider: :anthropic, temperature: 1.0, max_output_tokens: 16_384 }
    model = Smith::Tuning::Settings::ReflectionModel.build(setting)
    server.reply(json: message('{"idea":"Shorter.","instruction":"Answer in a phrase."}', tokens: [300, 40]))
    trial_id = Smith::Evals::Identity.reflection_trial_id(tuning_run_id: format("tu_%032x", 4), iteration: 2)

    call = described_class.new(model, scope: {}).call("The step's component: a.b", trial_id:)

    expect(call.output.transform_keys(&:to_s)).to eq("idea" => "Shorter.", "instruction" => "Answer in a phrase.")
    expect(call.steps.sole["settings"]).to eq("temperature" => 1.0, "max_output_tokens" => 16_384, "thinking" => nil)
    expect(call.steps.sole.values_at("model", "provider")).to eq(%w[claude-haiku-4-5 anthropic])
    body = server.requests.last.body
    expect(body.slice("model", "temperature", "max_tokens"))
      .to eq("model" => "claude-haiku-4-5", "temperature" => 1.0, "max_tokens" => 16_384)
    expect(body).not_to have_key("thinking")
  end

  it "tries a provider's overload again, the failed attempt costing a known 0, each attempt held on its ledger" do
    overloaded = { type: "error", error: { type: "overloaded_error", message: "Overloaded" } }
    server.reply(json: overloaded, status: "529 Overloaded").reply(json: message(reply, tokens: [300, 40]))

    call = reflect({ model: "claude-haiku-5-5", provider: :anthropic, attempts: 2, budget_ledger: ledger })

    expect(call.output.transform_keys(&:to_s)).to eq("idea" => "Shorter.", "instruction" => "Answer in a phrase.")
    expect(call.steps.map { _1.values_at("outcome", "cost_nanos", "cost_known") })
      .to eq([["failed", 0, true], ["completed", 1_500_000, true]])
    expect(call.steps.first.dig("failure", "kind")).to eq("transient")
    expect(call.usage.values_at("provider_calls", "cost_nanos", "cost_complete")).to eq([2, 1_500_000, true])
    expect([server.requests.size, ledger.kinds.count(:reserve)]).to eq([2, 2])
  end
end
