# frozen_string_literal: true

require "smith/doctor"

RSpec.describe Smith::Doctor::Checks::PersistenceCapabilities do
  before do
    @original_adapter = Smith.config.persistence_adapter
    @original_test_mode = Smith.config.test_mode
    Smith.instance_variable_set(:@_persistence_adapter, nil)
    Smith.instance_variable_set(:@_persistence_adapter_signature, nil)
  end

  after do
    Smith.configure do |c|
      c.persistence_adapter = @original_adapter
      c.test_mode = @original_test_mode
    end
    Smith.instance_variable_set(:@_persistence_adapter, nil)
    Smith.instance_variable_set(:@_persistence_adapter_signature, nil)
  end

  it "warns when no adapter is configured" do
    Smith.configure do |c|
      c.persistence_adapter = nil
      c.test_mode = false
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "persistence.capabilities" }
    expect(check.status).to eq(:warn)
    expect(check.message).to match(/No persistence adapter configured/)
  end

  it "passes when the configured adapter supports all optional capabilities" do
    Smith.configure do |c|
      c.persistence_adapter = Smith::PersistenceAdapters::Memory.new
      c.test_mode = false
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "persistence.capabilities" }
    expect(check.status).to eq(:pass)
    expect(check.message).to match(/Memory supports all optional persistence capabilities/)
    expect(check.detail).to include("store_versioned")
    expect(check.detail).to include("record_heartbeat")
    expect(check.detail).to include("last_heartbeat")
  end

  it "warns when the adapter is missing all optional capabilities" do
    cache_like = Class.new do
      def store(_key, _payload, **_opts); end
      def fetch(_key); end
      def delete(_key); end
    end.new

    Smith.configure do |c|
      c.persistence_adapter = cache_like
      c.test_mode = false
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "persistence.capabilities" }
    expect(check.status).to eq(:warn)
    expect(check.message).to match(/missing optional capabilities: store_versioned, record_heartbeat, last_heartbeat/)
    expect(check.detail).to include("payload updated_at parsing")
    expect(check.detail).to include("commit-aware split-step confirmation is unavailable")
  end

  it "warns when the adapter supports optimistic locking but not heartbeat probes" do
    versioned_only = Class.new do
      def store(_key, _payload, **_opts); end
      def fetch(_key); end
      def delete(_key); end
      def store_versioned(_key, _payload, expected_version:, **_opts); end
    end.new

    Smith.configure do |c|
      c.persistence_adapter = versioned_only
      c.test_mode = false
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "persistence.capabilities" }
    expect(check.status).to eq(:warn)
    expect(check.message).to match(/missing optional capabilities: record_heartbeat, last_heartbeat/)
    expect(check.message).not_to include("store_versioned,")
  end

  it "explains the conditional transaction identity requirement" do
    transactional = Class.new do
      def store(_key, _payload, **_opts); end
      def fetch(_key); end
      def delete(_key); end
      def transaction_open? = true
    end.new

    Smith.configure do |config|
      config.persistence_adapter = transactional
      config.test_mode = false
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |item| item.name == "persistence.capabilities" }
    expect(check.status).to eq(:warn)
    expect(check.message).to include("transaction_identity")
    expect(check.detail).to include("fails before writing")
  end
end
