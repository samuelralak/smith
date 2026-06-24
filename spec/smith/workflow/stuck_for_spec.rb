# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "Smith::Workflow.stuck_for?" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }

  def setup_workflow_class
    workflow_class_under_test = with_stubbed_class("StuckForWorkflow", workflow_class) do
      initial_state :idle
      state :working
      state :done

      transition :work, from: :idle, to: :working do
        compute { |_step| nil }
      end

      transition :finish, from: :working, to: :done do
        compute { |_step| nil }
      end
    end
    workflow_class_under_test
  end

  let(:workflow_klass) { setup_workflow_class }

  describe "argument validation" do
    it "raises WorkflowError when adapter is nil" do
      expect {
        workflow_klass.stuck_for?(persistence_key: "k", threshold: 60, adapter: nil)
      }.to raise_error(Smith::WorkflowError, /persistence_adapter is not configured/)
    end

    it "raises ArgumentError when persistence_key is blank" do
      expect {
        workflow_klass.stuck_for?(persistence_key: "", threshold: 60, adapter: adapter)
      }.to raise_error(ArgumentError, /persistence_key/)
    end

    it "raises ArgumentError when threshold lacks :to_i" do
      expect {
        workflow_klass.stuck_for?(persistence_key: "k", threshold: Object.new, adapter: adapter)
      }.to raise_error(ArgumentError, /threshold/)
    end

    it "raises ArgumentError when since: does not respond to :to_time" do
      no_time = Object.new
      expect {
        workflow_klass.stuck_for?(persistence_key: "k", threshold: 60, since: no_time, adapter: adapter)
      }.to raise_error(ArgumentError, /since must respond to :to_time/)
    end
  end

  describe "path A: payload present" do
    let(:key) { "stuck-for:path-a" }

    it "returns false when heartbeat is recent (younger than threshold)" do
      workflow_klass.run_persisted!(key: key, adapter: adapter, clear: false)
      expect(workflow_klass.stuck_for?(persistence_key: key, threshold: 60, adapter: adapter)).to be false
    end

    it "returns true when heartbeat is older than threshold and workflow is NOT terminal" do
      mid_klass = with_stubbed_class("StuckForMid", workflow_class) do
        initial_state :idle
        state :working
        state :done

        transition :work, from: :idle, to: :working do
          compute { |_step| nil }
        end

        transition :finish, from: :working, to: :done do
          compute { |_step| nil }
        end
      end

      wf = mid_klass.new
      wf.persist!(key, adapter: adapter)
      adapter.instance_variable_get(:@heartbeats)[key][:at] = Time.now.utc - 3600
      expect(mid_klass.stuck_for?(persistence_key: key, threshold: 60, adapter: adapter)).to be true
    end

    it "returns false when payload is present and reconstructed workflow IS terminal (:done)" do
      workflow_klass.run_persisted!(key: key, adapter: adapter, clear: false)
      adapter.instance_variable_get(:@heartbeats)[key][:at] = Time.now.utc - 3600
      expect(workflow_klass.stuck_for?(persistence_key: key, threshold: 60, adapter: adapter)).to be false
    end

    it "returns false when payload is present and reconstructed workflow IS terminal (:failed via state graph)" do
      terminal_failed = with_stubbed_class("StuckForTerminalFailed", workflow_class) do
        initial_state :idle
        state :failed
        transition :explode, from: :idle, to: :failed do
          compute { |_step| nil }
          on_failure :fail
        end
      end
      terminal_failed.run_persisted!(key: key, adapter: adapter, clear: false)
      adapter.instance_variable_get(:@heartbeats)[key][:at] = Time.now.utc - 3600
      expect(terminal_failed.stuck_for?(persistence_key: key, threshold: 60, adapter: adapter)).to be false
    end
  end

  describe "path B: no payload, since: kwarg" do
    let(:key) { "stuck-for:path-b" }

    it "returns true when since is older than threshold and no payload exists" do
      stale = Time.now.utc - 3600
      expect(workflow_klass.stuck_for?(persistence_key: key, threshold: 60, since: stale, adapter: adapter)).to be true
    end

    it "returns false when since is recent (within threshold)" do
      recent = Time.now.utc - 5
      expect(workflow_klass.stuck_for?(persistence_key: key, threshold: 60, since: recent, adapter: adapter)).to be false
    end

    it "returns false when since: is omitted and no payload exists" do
      expect(workflow_klass.stuck_for?(persistence_key: key, threshold: 60, adapter: adapter)).to be false
    end

    it "returns false when since is in the future (clock skew clamps to 0)" do
      future = Time.now.utc + 3600
      expect(workflow_klass.stuck_for?(persistence_key: key, threshold: 60, since: future, adapter: adapter)).to be false
    end

    it "accepts an ActiveSupport::TimeWithZone-like object (responds to :to_time)" do
      stale = Object.new
      stale.define_singleton_method(:to_time) { Time.now.utc - 3600 }
      expect(workflow_klass.stuck_for?(persistence_key: key, threshold: 60, since: stale, adapter: adapter)).to be true
    end
  end

  describe "fallback when adapter lacks last_heartbeat" do
    let(:legacy_adapter) do
      Class.new do
        def initialize
          @store = {}
        end

        def store(key, payload, **)
          @store[key] = payload
        end

        def fetch(key)
          @store[key]
        end

        def delete(key)
          @store.delete(key)
        end
      end.new
    end

    let(:key) { "stuck-for:legacy" }

    it "falls back to payload['updated_at'] parsing and emits a one-time warning" do
      old_payload = JSON.generate(
        class: "StuckForWorkflow",
        state: "working",
        updated_at: (Time.now.utc - 3600).iso8601,
        next_transition_name: nil
      )
      legacy_adapter.store(key, old_payload)
      old_logger = Smith.config.logger
      log_io = StringIO.new
      require "logger"
      Smith.config.logger = Logger.new(log_io)
      begin
        result = workflow_klass.stuck_for?(persistence_key: key, threshold: 60, adapter: legacy_adapter)
        expect(result).to be true
        expect(log_io.string).to include("does not implement record_heartbeat")
      ensure
        Smith.config.logger = old_logger
      end
    end
  end
end

RSpec.describe "Smith::Workflow.heartbeat_age" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:workflow_klass) do
    with_stubbed_class("HeartbeatAgeWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :work, from: :idle, to: :done do
        compute { |_step| nil }
      end
    end
  end

  it "returns nil when no payload exists" do
    expect(workflow_klass.heartbeat_age(persistence_key: "missing", adapter: adapter)).to be_nil
  end

  it "returns seconds since last heartbeat" do
    workflow_klass.run_persisted!(key: "k", adapter: adapter, clear: false)
    adapter.instance_variable_get(:@heartbeats)["k"][:at] = Time.now.utc - 30
    age = workflow_klass.heartbeat_age(persistence_key: "k", adapter: adapter)
    expect(age).to be_within(2).of(30.0)
  end

  it "clamps negative ages to 0.0" do
    workflow_klass.run_persisted!(key: "k", adapter: adapter, clear: false)
    adapter.instance_variable_get(:@heartbeats)["k"][:at] = Time.now.utc + 60
    expect(workflow_klass.heartbeat_age(persistence_key: "k", adapter: adapter)).to eq(0.0)
  end
end

RSpec.describe "Smith::PersistenceAdapters::Memory heartbeat" do
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }

  it "returns nil when no heartbeat has been recorded" do
    expect(adapter.last_heartbeat("k")).to be_nil
  end

  it "round-trips record_heartbeat / last_heartbeat" do
    adapter.record_heartbeat("k")
    hb = adapter.last_heartbeat("k")
    expect(hb).to be_a(Time)
    expect(hb).to be_within(1).of(Time.now.utc)
  end

  it "is cleared when delete is called" do
    adapter.store("k", "payload")
    adapter.record_heartbeat("k")
    adapter.delete("k")
    expect(adapter.last_heartbeat("k")).to be_nil
  end

  it "honors TTL: expired heartbeat returns nil" do
    adapter.record_heartbeat("k", ttl: 0)
    sleep 0.01
    expect(adapter.last_heartbeat("k")).to be_nil
  end
end

RSpec.describe "Workflow#persist! writes heartbeat via dispatch_store!" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }

  it "writes a heartbeat after a successful persist! on adapters that support it" do
    workflow_klass = with_stubbed_class("HeartbeatPersistWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :work, from: :idle, to: :done do
        compute { |_step| nil }
      end
    end

    workflow_klass.run_persisted!(key: "hb-test", adapter: adapter, clear: false)
    expect(adapter.last_heartbeat("hb-test")).not_to be_nil
  end
end
