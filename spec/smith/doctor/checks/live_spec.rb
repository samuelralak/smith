# frozen_string_literal: true

require "smith/doctor"

RSpec.describe Smith::Doctor::Checks::Live do
  it "warns (not fails) when no RubyLLM provider credentials detected" do
    report = Smith::Doctor::Report.new

    allow(described_class).to receive(:ruby_llm_configured?).and_return(false)
    described_class.run(report)

    config_check = report.checks.find { |c| c.name == "live.provider_config" }
    expect(config_check.status).to eq(:warn)
  end

  it "attempts model call regardless of provider config status" do
    report = Smith::Doctor::Report.new

    allow(described_class).to receive(:ruby_llm_configured?).and_return(false)
    allow(described_class).to receive(:attempt_model_call) do |r|
      r.add(name: "live.model_call", status: :fail, message: "call failed")
    end

    described_class.run(report)

    names = report.checks.map(&:name)
    expect(names).to include("live.model_call")
  end

  it "fails gracefully on StandardError during model call" do
    report = Smith::Doctor::Report.new

    allow(RubyLLM).to receive(:chat).and_raise(StandardError, "connection refused")
    described_class.run(report)

    call_check = report.checks.find { |c| c.name == "live.model_call" }
    expect(call_check.status).to eq(:fail)
    expect(call_check.detail).to include("connection refused")
  end
end
