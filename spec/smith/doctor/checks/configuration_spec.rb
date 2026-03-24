# frozen_string_literal: true

require "smith/doctor"

RSpec.describe Smith::Doctor::Checks::Configuration do
  it "warns when config.logger is nil" do
    original = Smith.config.logger
    Smith.configure { |c| c.logger = nil }

    report = Smith::Doctor::Report.new
    described_class.run(report)

    logger_check = report.checks.find { |c| c.name == "config.logger" }
    expect(logger_check.status).to eq(:warn)
  ensure
    Smith.configure { |c| c.logger = original }
  end

  it "passes when config.logger is set" do
    original = Smith.config.logger
    Smith.configure { |c| c.logger = Logger.new(File::NULL) }

    report = Smith::Doctor::Report.new
    described_class.run(report)

    logger_check = report.checks.find { |c| c.name == "config.logger" }
    expect(logger_check.status).to eq(:pass)
  ensure
    Smith.configure { |c| c.logger = original }
  end

  it "warns when config.pricing is nil" do
    original = Smith.config.pricing
    Smith.configure { |c| c.pricing = nil }

    report = Smith::Doctor::Report.new
    described_class.run(report)

    pricing_check = report.checks.find { |c| c.name == "config.pricing" }
    expect(pricing_check.status).to eq(:warn)
  ensure
    Smith.configure { |c| c.pricing = original }
  end

  it "passes when config.pricing is a populated Hash" do
    original = Smith.config.pricing
    Smith.configure { |c| c.pricing = { "gpt-4.1-nano" => { input_cost_per_token: 0.01 } } }

    report = Smith::Doctor::Report.new
    described_class.run(report)

    pricing_check = report.checks.find { |c| c.name == "config.pricing" }
    expect(pricing_check.status).to eq(:pass)
  ensure
    Smith.configure { |c| c.pricing = original }
  end
end
