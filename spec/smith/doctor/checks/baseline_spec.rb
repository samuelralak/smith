# frozen_string_literal: true

require "smith/doctor"

RSpec.describe Smith::Doctor::Checks::Baseline do
  it "passes all baseline checks in the test environment" do
    report = Smith::Doctor::Report.new
    described_class.run(report)

    statuses = report.checks.map(&:status)
    expect(statuses).to all(eq(:pass))
    expect(report.checks.length).to eq(6)
  end
end
