# frozen_string_literal: true

require "smith/doctor"

RSpec.describe Smith::Doctor do
  it "returns a report with baseline and config checks by default" do
    report = described_class.run(io: StringIO.new)

    names = report.checks.map(&:name)
    expect(names).to include("baseline.smith_loads")
    expect(names).to include("config.logger")
    expect(report).to be_a(Smith::Doctor::Report)
  end

  it "includes serialization and durability checks when durability: true" do
    report = described_class.run(durability: true, io: StringIO.new)

    names = report.checks.map(&:name)
    expect(names).to include("serialization.to_state")
    expect(names).to include("durability.adapter")
  end

  it "includes persistence checks when profile: :rails_persistence" do
    report = described_class.run(profile: :rails_persistence, io: StringIO.new)

    names = report.checks.map(&:name)
    expect(names).to include("persistence.active_record")
  end

  it "includes live checks when live: true" do
    allow(Smith::Doctor::Checks::Live).to receive(:ruby_llm_configured?).and_return(false)
    allow(RubyLLM).to receive(:chat).and_raise(StandardError, "no provider")

    report = described_class.run(live: true, io: StringIO.new)

    names = report.checks.map(&:name)
    expect(names).to include("live.provider_config")
    expect(names).to include("live.model_call")
  end
end
