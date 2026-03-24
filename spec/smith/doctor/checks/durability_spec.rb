# frozen_string_literal: true

require "smith/doctor"

RSpec.describe Smith::Doctor::Checks::Durability do
  it "warns when no persistence_adapter is configured" do
    original = Smith.config.persistence_adapter
    Smith.configure { |c| c.persistence_adapter = nil }

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "durability.adapter" }
    expect(check.status).to eq(:warn)
    expect(check.message).to include("No persistence adapter configured")
  ensure
    Smith.configure { |c| c.persistence_adapter = original }
  end

  it "passes persist_restore and resume_after_restore with working adapter" do
    store = {}
    adapter = Object.new
    adapter.define_singleton_method(:store) { |key, payload| store[key] = payload }
    adapter.define_singleton_method(:fetch) { |key| store[key] }
    adapter.define_singleton_method(:delete) { |key| store.delete(key) }

    original = Smith.config.persistence_adapter
    Smith.configure { |c| c.persistence_adapter = adapter }

    report = Smith::Doctor::Report.new
    described_class.run(report)

    persist_check = report.checks.find { |c| c.name == "durability.persist_restore" }
    resume_check = report.checks.find { |c| c.name == "durability.resume_after_restore" }
    expect(persist_check.status).to eq(:pass)
    expect(resume_check.status).to eq(:pass)
  ensure
    Smith.configure { |c| c.persistence_adapter = original }
  end

  it "fails when adapter returns corrupted data" do
    adapter = Object.new
    adapter.define_singleton_method(:store) { |_key, _payload| nil }
    adapter.define_singleton_method(:fetch) { |_key| "not json" }
    adapter.define_singleton_method(:delete) { |_key| nil }

    original = Smith.config.persistence_adapter
    Smith.configure { |c| c.persistence_adapter = adapter }

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "durability.persist_restore" }
    expect(check.status).to eq(:fail)
  ensure
    Smith.configure { |c| c.persistence_adapter = original }
  end
end
