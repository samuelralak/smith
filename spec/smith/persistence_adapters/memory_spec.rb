# frozen_string_literal: true

RSpec.describe Smith::PersistenceAdapters::Memory do
  subject(:adapter) { described_class.new }

  describe "REQUIRED_METHODS contract" do
    it "responds to store/fetch/delete" do
      Smith::PersistenceAdapters::REQUIRED_METHODS.each do |method|
        expect(adapter).to respond_to(method)
      end
    end

    it "passes Smith::PersistenceAdapters.adapter_like?" do
      expect(Smith::PersistenceAdapters.adapter_like?(adapter)).to be(true)
    end
  end

  describe "store / fetch / delete" do
    it "round-trips a payload" do
      adapter.store("k", "payload-value")
      expect(adapter.fetch("k")).to eq("payload-value")
    end

    it "returns nil for unknown keys" do
      expect(adapter.fetch("nope")).to be_nil
    end

    it "removes a key on delete" do
      adapter.store("k", "v")
      adapter.delete("k")
      expect(adapter.fetch("k")).to be_nil
    end
  end

  describe "TTL" do
    it "expires entries after the configured TTL" do
      adapter.store("k", "v", ttl: 0.05)
      expect(adapter.fetch("k")).to eq("v")
      sleep(0.1)
      expect(adapter.fetch("k")).to be_nil
    end

    it "uses Smith.config.persistence_ttl as a default when ttl: kwarg is omitted" do
      Smith.config.persistence_ttl = 0.05
      adapter.store("k", "v")
      sleep(0.1)
      expect(adapter.fetch("k")).to be_nil
    ensure
      Smith.config.persistence_ttl = nil
    end

    it "respects nil TTL (no expiry)" do
      adapter.store("k", "v", ttl: nil)
      expect(adapter.fetch("k")).to eq("v")
    end
  end

  describe "store_versioned (optional capability)" do
    it "responds to store_versioned" do
      expect(adapter).to respond_to(:store_versioned)
    end

    it "is reported as supporting :store_versioned" do
      expect(Smith::PersistenceAdapters.supports?(adapter, :store_versioned)).to be(true)
    end

    it "stores an initial payload with expected_version: 0" do
      adapter.store_versioned("k", JSON.generate(persistence_version: 1), expected_version: 0)
      expect(JSON.parse(adapter.fetch("k"))).to eq("persistence_version" => 1)
    end

    it "accepts the next version when expected matches current" do
      adapter.store_versioned("k", JSON.generate(persistence_version: 1), expected_version: 0)
      adapter.store_versioned("k", JSON.generate(persistence_version: 2), expected_version: 1)
      expect(JSON.parse(adapter.fetch("k"))).to eq("persistence_version" => 2)
    end

    it "raises PersistenceVersionConflict when expected_version is stale" do
      adapter.store_versioned("k", JSON.generate(persistence_version: 1), expected_version: 0)
      expect do
        adapter.store_versioned("k", JSON.generate(persistence_version: 5), expected_version: 0)
      end.to raise_error(Smith::PersistenceVersionConflict) do |err|
        expect(err.key).to eq("k")
        expect(err.expected).to eq(0)
        expect(err.actual).to eq(1)
      end
    end
  end

  describe "thread safety" do
    it "serializes concurrent writes via Monitor" do
      results = []
      threads = 5.times.map do |i|
        Thread.new do
          adapter.store("shared", "value-#{i}")
          results << adapter.fetch("shared")
        end
      end
      threads.each(&:join)
      # All reads should observe SOME value (no torn writes / nil races)
      expect(results.compact.size).to eq(5)
    end
  end

  describe "Smith::PersistenceAdapters.resolve(:memory)" do
    it "returns a Memory instance" do
      expect(Smith::PersistenceAdapters.resolve(:memory)).to be_a(described_class)
    end
  end

  describe "#clear!" do
    it "removes all keys (test-isolation helper)" do
      adapter.store("a", "1")
      adapter.store("b", "2")
      adapter.store("c", "3")

      adapter.clear!

      expect(adapter.fetch("a")).to be_nil
      expect(adapter.fetch("b")).to be_nil
      expect(adapter.fetch("c")).to be_nil
    end

    it "is safe to call on an empty store" do
      expect { adapter.clear! }.not_to raise_error
    end
  end

  describe "Smith.persistence_adapter test_mode auto-detect" do
    before do
      Smith.config.persistence_adapter = nil
      Smith.instance_variable_set(:@_persistence_adapter_signature, nil)
      Smith.instance_variable_set(:@_persistence_adapter, nil)
    end
    after { Smith.config.test_mode = false }

    it "auto-selects Memory when no adapter is configured AND test_mode is true" do
      Smith.config.test_mode = true
      expect(Smith.persistence_adapter).to be_a(described_class)
    end

    it "returns nil when no adapter is configured AND test_mode is false" do
      Smith.config.test_mode = false
      expect(Smith.persistence_adapter).to be_nil
    end
  end
end
