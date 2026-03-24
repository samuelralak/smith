# frozen_string_literal: true

RSpec.describe Smith::PersistenceAdapters do
  describe ".resolve" do
    let(:custom_adapter) do
      Object.new.tap do |adapter|
        adapter.define_singleton_method(:store) { |_key, _payload| nil }
        adapter.define_singleton_method(:fetch) { |_key| nil }
        adapter.define_singleton_method(:delete) { |_key| nil }
      end
    end

    it "returns nil when no adapter is configured" do
      expect(described_class.resolve(nil)).to be_nil
    end

    it "passes through custom adapter objects that implement the adapter API" do
      expect(described_class.resolve(custom_adapter)).to equal(custom_adapter)
    end

    it "resolves :cache_store with the provided store and namespace" do
      store = instance_double("CacheStore")
      expect(store).to receive(:write).with("smith-spec:probe", "payload")
      expect(store).to receive(:read).with("smith-spec:probe").and_return("payload")
      expect(store).to receive(:delete).with("smith-spec:probe")

      adapter = described_class.resolve(:cache_store, store:, namespace: "smith-spec")

      adapter.store("probe", "payload")
      expect(adapter.fetch("probe")).to eq("payload")
      adapter.delete("probe")
    end

    it "resolves :rails_cache through Rails.cache" do
      cache = instance_double("RailsCache")
      stub_const("Rails", Class.new)
      allow(Rails).to receive(:cache).and_return(cache)
      expect(cache).to receive(:write).with("smith:probe", "payload")

      adapter = described_class.resolve(:rails_cache)
      adapter.store("probe", "payload")
    end

    it "resolves :solid_cache as an alias for Rails.cache-backed storage" do
      cache = instance_double("RailsCache")
      stub_const("Rails", Class.new)
      allow(Rails).to receive(:cache).and_return(cache)
      expect(cache).to receive(:write).with("solid:probe", "payload")

      adapter = described_class.resolve(:solid_cache, namespace: "solid")
      adapter.store("probe", "payload")
    end

    it "resolves :redis with the provided client and namespace" do
      redis = instance_double("Redis")
      expect(redis).to receive(:set).with("smith-redis:probe", "payload")
      expect(redis).to receive(:get).with("smith-redis:probe").and_return("payload")
      expect(redis).to receive(:del).with("smith-redis:probe")

      adapter = described_class.resolve(:redis, redis:, namespace: "smith-redis")

      adapter.store("probe", "payload")
      expect(adapter.fetch("probe")).to eq("payload")
      adapter.delete("probe")
    end

    it "resolves :active_record with the configured model and columns" do
      relation = instance_double("Relation", delete_all: 1)
      record = instance_double("WorkflowState")

      model = Class.new do
        def self.find_or_initialize_by(*); end
        def self.find_by(*); end
        def self.where(*); end
      end

      allow(model).to receive(:find_or_initialize_by).with(key: "probe").and_return(record)
      allow(record).to receive(:payload=).with("payload")
      allow(record).to receive(:save!)
      allow(model).to receive(:find_by).with(key: "probe").and_return(record)
      allow(record).to receive(:payload).and_return("payload")
      allow(model).to receive(:where).with(key: "probe").and_return(relation)

      adapter = described_class.resolve(:active_record, model:)

      adapter.store("probe", "payload")
      expect(adapter.fetch("probe")).to eq("payload")
      adapter.delete("probe")
    end

    it "instantiates custom adapter classes with keyword options" do
      custom_class = Class.new do
        attr_reader :label

        def initialize(label:)
          @label = label
        end

        def store(_key, _payload); end
        def fetch(_key); end
        def delete(_key); end
      end

      adapter = described_class.resolve(custom_class, label: "custom")
      expect(adapter.label).to eq("custom")
    end

    it "fails when a custom adapter class does not implement the adapter contract" do
      invalid_class = Class.new do
        def initialize; end
      end

      expect do
        described_class.resolve(invalid_class)
      end.to raise_error(ArgumentError, /must implement/)
    end

    it "raises for unknown built-in adapter symbols" do
      expect do
        described_class.resolve(:unknown)
      end.to raise_error(ArgumentError, /Unknown persistence adapter/)
    end
  end
end
