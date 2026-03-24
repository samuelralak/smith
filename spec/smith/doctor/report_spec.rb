# frozen_string_literal: true

require "smith/doctor"

RSpec.describe Smith::Doctor::Report do
  it "is passed with no checks" do
    report = described_class.new
    expect(report.passed?).to be true
    expect(report.exit_code).to eq(0)
  end

  it "is passed with only :pass checks" do
    report = described_class.new
    report.add(name: "a.one", status: :pass, message: "ok")
    report.add(name: "a.two", status: :pass, message: "ok")
    expect(report.passed?).to be true
    expect(report.exit_code).to eq(0)
  end

  it "is failed with one :fail check" do
    report = described_class.new
    report.add(name: "a.one", status: :pass, message: "ok")
    report.add(name: "a.two", status: :fail, message: "bad")
    expect(report.passed?).to be false
    expect(report.exit_code).to eq(1)
  end

  it "is passed with :warn but no :fail" do
    report = described_class.new
    report.add(name: "a.one", status: :pass, message: "ok")
    report.add(name: "a.two", status: :warn, message: "caution")
    expect(report.passed?).to be true
  end

  it "counts pass/warn/fail/skip in summary" do
    report = described_class.new
    report.add(name: "a.one", status: :pass, message: "ok")
    report.add(name: "a.two", status: :warn, message: "caution")
    report.add(name: "a.three", status: :fail, message: "bad")
    report.add(name: "a.four", status: :skip, message: "skipped")
    expect(report.summary).to include("1 passed")
    expect(report.summary).to include("1 warnings")
    expect(report.summary).to include("1 failed")
    expect(report.summary).to include("1 skipped")
  end

  it "groups checks by first name segment" do
    report = described_class.new
    report.add(name: "baseline.one", status: :pass, message: "a")
    report.add(name: "baseline.two", status: :pass, message: "b")
    report.add(name: "config.one", status: :warn, message: "c")
    grouped = report.grouped
    expect(grouped.keys).to eq(%w[baseline config])
    expect(grouped["baseline"].length).to eq(2)
    expect(grouped["config"].length).to eq(1)
  end
end
