# frozen_string_literal: true

require "smith/doctor"

RSpec.describe Smith::Doctor::Checks::Serialization do
  it "passes all serialization checks" do
    report = Smith::Doctor::Report.new
    described_class.run(report)

    statuses = report.checks.map(&:status)
    expect(statuses).to all(eq(:pass))
    expect(report.checks.length).to eq(4)
  end
end
