# frozen_string_literal: true

require "smith/doctor"

RSpec.describe Smith::Doctor::Checks::Durability do
  it "warns when no persistence_adapter is configured" do
    original = Smith.config.persistence_adapter
    original_options = Smith.config.persistence_options
    Smith.configure { |c| c.persistence_adapter = nil }

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "durability.adapter" }
    expect(check.status).to eq(:warn)
    expect(check.message).to include("No persistence adapter configured")
  ensure
    Smith.configure do |c|
      c.persistence_adapter = original
      c.persistence_options = original_options
    end
  end

  it "passes persist_restore and resume_after_restore with working adapter" do
    store = {}
    adapter = Object.new
    adapter.define_singleton_method(:store) { |key, payload| store[key] = payload }
    adapter.define_singleton_method(:fetch) { |key| store[key] }
    adapter.define_singleton_method(:delete) { |key| store.delete(key) }

    original = Smith.config.persistence_adapter
    original_options = Smith.config.persistence_options
    Smith.configure do |c|
      c.persistence_adapter = adapter
      c.persistence_options = {}
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    persist_check = report.checks.find { |c| c.name == "durability.persist_restore" }
    resume_check = report.checks.find { |c| c.name == "durability.resume_after_restore" }
    expect(persist_check.status).to eq(:pass)
    expect(resume_check.status).to eq(:pass)
  ensure
    Smith.configure do |c|
      c.persistence_adapter = original
      c.persistence_options = original_options
    end
  end

  it "fails when adapter returns corrupted data" do
    adapter = Object.new
    adapter.define_singleton_method(:store) { |_key, _payload| nil }
    adapter.define_singleton_method(:fetch) { |_key| "not json" }
    adapter.define_singleton_method(:delete) { |_key| nil }

    original = Smith.config.persistence_adapter
    original_options = Smith.config.persistence_options
    Smith.configure do |c|
      c.persistence_adapter = adapter
      c.persistence_options = {}
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "durability.persist_restore" }
    expect(check.status).to eq(:fail)
  ensure
    Smith.configure do |c|
      c.persistence_adapter = original
      c.persistence_options = original_options
    end
  end

  it "resolves built-in symbol adapters through persistence_options" do
    store = {}
    cache = Object.new
    cache.define_singleton_method(:write) { |key, payload| store[key] = payload }
    cache.define_singleton_method(:read) { |key| store[key] }
    cache.define_singleton_method(:delete) { |key| store.delete(key) }

    original = Smith.config.persistence_adapter
    original_options = Smith.config.persistence_options
    Smith.configure do |c|
      c.persistence_adapter = :cache_store
      c.persistence_options = { store: cache, namespace: "smith-test" }
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    persist_check = report.checks.find { |c| c.name == "durability.persist_restore" }
    resume_check = report.checks.find { |c| c.name == "durability.resume_after_restore" }
    expect(persist_check.status).to eq(:pass)
    expect(resume_check.status).to eq(:pass)
  ensure
    Smith.configure do |c|
      c.persistence_adapter = original
      c.persistence_options = original_options
    end
  end

  it "fails cleanly when built-in adapter configuration is invalid" do
    original = Smith.config.persistence_adapter
    original_options = Smith.config.persistence_options
    Smith.configure do |c|
      c.persistence_adapter = :cache_store
      c.persistence_options = {}
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "durability.adapter" }
    expect(check.status).to eq(:fail)
    expect(check.message).to include("invalid")
  ensure
    Smith.configure do |c|
      c.persistence_adapter = original
      c.persistence_options = original_options
    end
  end

  it "fails cleanly when :rails_cache cannot resolve Rails.cache" do
    stub_const("Rails", Class.new)
    allow(Rails).to receive(:respond_to?).with(:cache).and_return(true)
    allow(Rails).to receive(:cache).and_return(nil)

    original = Smith.config.persistence_adapter
    original_options = Smith.config.persistence_options
    Smith.configure do |c|
      c.persistence_adapter = :rails_cache
      c.persistence_options = {}
    end

    report = Smith::Doctor::Report.new

    expect { described_class.run(report) }.not_to raise_error

    check = report.checks.find { |c| c.name == "durability.adapter" }
    expect(check.status).to eq(:fail)
    expect(check.message).to include("invalid")
    expect(check.detail).to include("Rails.cache is not available")
  ensure
    Smith.configure do |c|
      c.persistence_adapter = original
      c.persistence_options = original_options
    end
  end

  it "warns when :rails_cache resolves to a process-local memory store" do
    stub_const("MemoryStore", Class.new do
      def initialize
        @store = {}
      end

      def write(key, payload)
        @store[key] = payload
      end

      def read(key)
        @store[key]
      end

      def delete(key)
        @store.delete(key)
      end
    end)

    stub_const("Rails", Class.new)
    allow(Rails).to receive(:cache).and_return(MemoryStore.new)

    original = Smith.config.persistence_adapter
    original_options = Smith.config.persistence_options
    Smith.configure do |c|
      c.persistence_adapter = :rails_cache
      c.persistence_options = {}
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    backend_check = report.checks.find { |c| c.name == "durability.backend" }
    persist_check = report.checks.find { |c| c.name == "durability.persist_restore" }
    expect(backend_check.status).to eq(:warn)
    expect(backend_check.message).to include("process-local memory")
    expect(persist_check.status).to eq(:pass)
  ensure
    Smith.configure do |c|
      c.persistence_adapter = original
      c.persistence_options = original_options
    end
  end

  it "warns when :cache_store wraps a process-local memory backend" do
    stub_const("MemoryStore", Class.new do
      def initialize
        @store = {}
      end

      def write(key, payload)
        @store[key] = payload
      end

      def read(key)
        @store[key]
      end

      def delete(key)
        @store.delete(key)
      end
    end)

    original = Smith.config.persistence_adapter
    original_options = Smith.config.persistence_options
    Smith.configure do |c|
      c.persistence_adapter = :cache_store
      c.persistence_options = {
        store: MemoryStore.new,
        namespace: "smith-test"
      }
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    backend_check = report.checks.find { |c| c.name == "durability.backend" }
    persist_check = report.checks.find { |c| c.name == "durability.persist_restore" }
    expect(backend_check.status).to eq(:warn)
    expect(backend_check.message).to include("process-local memory")
    expect(persist_check.status).to eq(:pass)
  ensure
    Smith.configure do |c|
      c.persistence_adapter = original
      c.persistence_options = original_options
    end
  end

  it "fails cleanly when :cache_store backend resolution raises during warning evaluation" do
    original = Smith.config.persistence_adapter
    original_options = Smith.config.persistence_options
    Smith.configure do |c|
      c.persistence_adapter = :cache_store
      c.persistence_options = {
        store: -> { raise ArgumentError, "backend unavailable" },
        namespace: "smith-test"
      }
    end

    report = Smith::Doctor::Report.new

    expect { described_class.run(report) }.not_to raise_error

    check = report.checks.find { |c| c.name == "durability.adapter" }
    expect(check.status).to eq(:fail)
    expect(check.message).to include("invalid")
    expect(check.detail).to include("backend unavailable")
  ensure
    Smith.configure do |c|
      c.persistence_adapter = original
      c.persistence_options = original_options
    end
  end
end
