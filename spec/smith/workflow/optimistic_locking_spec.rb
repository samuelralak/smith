# frozen_string_literal: true

# Pins the optimistic-locking contract: when an adapter supports
# `store_versioned`, two concurrent processes restoring the same key
# and racing on persist will see the second writer's persist fail with
# Smith::PersistenceVersionConflict.

RSpec.describe "Smith::Workflow optimistic locking via store_versioned" do
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:workflow_class) do
    Class.new(Smith::Workflow) do
      persistence_key { |_ctx| "workflow:optimistic-test" }
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end
  end

  it "increments @persistence_version on each persist!" do
    workflow = workflow_class.new
    expect(workflow.instance_variable_get(:@persistence_version)).to eq(0)

    workflow.persist!("workflow:optimistic-test", adapter: adapter)
    expect(workflow.instance_variable_get(:@persistence_version)).to eq(1)

    workflow.persist!("workflow:optimistic-test", adapter: adapter)
    expect(workflow.instance_variable_get(:@persistence_version)).to eq(2)
  end

  it "stores the persistence_version inside the JSON payload" do
    workflow = workflow_class.new
    workflow.persist!("workflow:optimistic-test", adapter: adapter)
    workflow.persist!("workflow:optimistic-test", adapter: adapter)

    payload = adapter.fetch("workflow:optimistic-test")
    expect(JSON.parse(payload)["persistence_version"]).to eq(2)
  end

  it "raises Smith::PersistenceVersionConflict when two restored copies race on persist" do
    # First writer establishes v1
    w1 = workflow_class.new
    w1.persist!("workflow:optimistic-test", adapter: adapter)

    # Both readers restore at v1 (capture @persistence_version = 1)
    w2 = workflow_class.restore("workflow:optimistic-test", adapter: adapter)
    w3 = workflow_class.restore("workflow:optimistic-test", adapter: adapter)
    expect(w2.instance_variable_get(:@persistence_version)).to eq(1)
    expect(w3.instance_variable_get(:@persistence_version)).to eq(1)

    # w2 persists first → store now has v2
    w2.persist!("workflow:optimistic-test", adapter: adapter)

    # w3 tries to persist with expected_version=1 → conflict (stored is v2)
    expect do
      w3.persist!("workflow:optimistic-test", adapter: adapter)
    end.to raise_error(Smith::PersistenceVersionConflict) do |err|
      expect(err.key).to eq("workflow:optimistic-test")
      expect(err.expected).to eq(1)
    end

    # w3's @persistence_version stays at the pre-failure value so the
    # host can rescue + restore + retry without state corruption.
    expect(w3.instance_variable_get(:@persistence_version)).to eq(1)
  end

  it "restores @persistence_version from the persisted payload" do
    w1 = workflow_class.new
    w1.persist!("workflow:optimistic-test", adapter: adapter)
    w1.persist!("workflow:optimistic-test", adapter: adapter)
    w1.persist!("workflow:optimistic-test", adapter: adapter)

    restored = workflow_class.restore("workflow:optimistic-test", adapter: adapter)
    expect(restored.instance_variable_get(:@persistence_version)).to eq(3)
  end

  it "treats a pre-versioning payload (no persistence_version key) as version 0 on restore" do
    # Simulate legacy state stored without persistence_version
    legacy_payload = {
      class: workflow_class.name, state: :idle, persistence_key: "workflow:optimistic-test",
      context: {}, budget_consumed: {}, step_count: 0,
      created_at: Time.now.utc.iso8601, updated_at: Time.now.utc.iso8601,
      session_messages: [], total_cost: 0.0, total_tokens: 0,
      tool_results: [], outcome: nil, usage_entries: [],
      last_output: nil, last_failed_step: nil
      # Note: no :persistence_version key
    }
    adapter.store("workflow:optimistic-test", JSON.generate(legacy_payload))

    restored = workflow_class.restore("workflow:optimistic-test", adapter: adapter)
    expect(restored.instance_variable_get(:@persistence_version)).to eq(0)
  end

  describe "adapters without store_versioned (CacheStore family)" do
    # Anonymous adapter that implements only the required contract.
    let(:non_versioned_adapter) do
      Class.new do
        def initialize
          @store = {}
        end

        def store(key, payload)
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

    it "falls back to plain store + one-time warning when adapter lacks store_versioned" do
      logger = instance_double("Logger")
      allow(logger).to receive(:warn)
      original_logger = Smith.config.logger
      Smith.config.logger = logger

      # Reset the warned-classes set so this test's adapter class gets fresh warning state
      Smith::PersistenceAdapters.instance_variable_set(:@_warned_classes, Set.new)

      workflow = workflow_class.new
      expect { workflow.persist!("workflow:optimistic-test", adapter: non_versioned_adapter) }.not_to raise_error

      expect(logger).to have_received(:warn).with(/does not implement store_versioned/).once
    ensure
      Smith.config.logger = original_logger
    end

    it "still increments @persistence_version even without optimistic-locking enforcement" do
      workflow = workflow_class.new
      workflow.persist!("workflow:optimistic-test", adapter: non_versioned_adapter)
      expect(workflow.instance_variable_get(:@persistence_version)).to eq(1)
    end
  end
end
