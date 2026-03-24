# frozen_string_literal: true

require "smith/cli"

RSpec.describe Smith::CLI do
  it "returns exit_code from doctor report for doctor command" do
    allow(Smith::Doctor).to receive(:run).and_return(
      instance_double(Smith::Doctor::Report, exit_code: 0)
    )

    result = described_class.new(["doctor"]).run
    expect(result).to eq(0)
  end

  it "returns 0 for version command" do
    allow($stdout).to receive(:puts)
    result = described_class.new(["version"]).run
    expect(result).to eq(0)
  end

  it "returns 1 for unknown command" do
    allow($stderr).to receive(:write)
    result = described_class.new(["nonsense"]).run
    expect(result).to eq(1)
  end

  it "returns 0 for --help" do
    allow($stdout).to receive(:puts)
    result = described_class.new(["--help"]).run
    expect(result).to eq(0)
  end
end
