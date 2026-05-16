# frozen_string_literal: true

# Pins the persistence_schema_version + migrate_from contract: stored
# payloads carry :schema_version, restore dispatches through registered
# migrations one step at a time, and unbridged gaps raise
# Smith::PersistenceSchemaMismatch with actionable diagnostics.

RSpec.describe "Smith::Workflow schema versioning" do
  let(:base_payload) do
    {
      class: "SpecVersionedWorkflow",
      state: :idle,
      persistence_key: "workflow:versioned",
      context: {},
      budget_consumed: {},
      step_count: 0,
      created_at: Time.now.utc.iso8601,
      updated_at: Time.now.utc.iso8601,
      session_messages: [],
      total_cost: 0.0,
      total_tokens: 0,
      tool_results: [],
      outcome: nil,
      usage_entries: [],
      last_output: nil,
      last_failed_step: nil,
      persistence_version: 0
    }
  end

  it "defaults persistence_schema_version to 1" do
    workflow_class = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end

    expect(workflow_class.persistence_schema_version).to eq(1)
  end

  it "to_state carries the workflow class's persistence_schema_version" do
    workflow_class = Class.new(Smith::Workflow) do
      persistence_schema_version 3
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end

    workflow = workflow_class.new
    expect(workflow.to_state[:schema_version]).to eq(3)
  end

  it "round-trips when stored schema_version matches current" do
    workflow_class = Class.new(Smith::Workflow) do
      persistence_schema_version 2
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end

    payload = base_payload.merge(schema_version: 2)
    workflow = workflow_class.from_state(payload)
    expect(workflow.to_state[:schema_version]).to eq(2)
  end

  it "raises Smith::PersistenceSchemaMismatch when stored version lags and no migration registered" do
    workflow_class = Class.new(Smith::Workflow) do
      persistence_schema_version 2
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end

    payload = base_payload.merge(schema_version: 1)
    expect { workflow_class.from_state(payload) }.to raise_error(Smith::PersistenceSchemaMismatch) do |err|
      expect(err.stored).to eq(1)
      expect(err.current).to eq(2)
      expect(err.message).to match(/stored v1, current v2/)
      expect(err.message).to match(/migrate_from\(1\)/)
    end
  end

  it "raises Smith::PersistenceSchemaMismatch on downgrade (stored greater than current)" do
    workflow_class = Class.new(Smith::Workflow) do
      persistence_schema_version 1
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end

    payload = base_payload.merge(schema_version: 5)
    expect { workflow_class.from_state(payload) }.to raise_error(Smith::PersistenceSchemaMismatch, /stored v5, current v1/)
  end

  it "applies a registered migration to bridge stored v1 to current v2" do
    workflow_class = Class.new(Smith::Workflow) do
      persistence_schema_version 2
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done

      migrate_from 1 do |payload|
        payload[:schema_version] = 2
        payload[:context] = (payload[:context] || {}).merge(added_in_v2: "default")
        payload
      end
    end

    payload = base_payload.merge(schema_version: 1)
    workflow = workflow_class.from_state(payload)
    expect(workflow.instance_variable_get(:@context)[:added_in_v2]).to eq("default")
    expect(workflow.to_state[:schema_version]).to eq(2)
  end

  it "chains registered migrations across multiple version steps (v1 -> v2 -> v3)" do
    workflow_class = Class.new(Smith::Workflow) do
      persistence_schema_version 3
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done

      migrate_from 1 do |payload|
        payload[:schema_version] = 2
        payload[:context] = (payload[:context] || {}).merge(step_v1_to_v2: true)
        payload
      end

      migrate_from 2 do |payload|
        payload[:schema_version] = 3
        payload[:context] = (payload[:context] || {}).merge(step_v2_to_v3: true)
        payload
      end
    end

    payload = base_payload.merge(schema_version: 1)
    workflow = workflow_class.from_state(payload)
    expect(workflow.instance_variable_get(:@context)[:step_v1_to_v2]).to be(true)
    expect(workflow.instance_variable_get(:@context)[:step_v2_to_v3]).to be(true)
    expect(workflow.to_state[:schema_version]).to eq(3)
  end

  it "raises PersistenceSchemaMismatch when a chain step is missing" do
    workflow_class = Class.new(Smith::Workflow) do
      persistence_schema_version 3
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done

      # Only v1 -> v2 registered; v2 -> v3 missing.
      migrate_from 1 do |payload|
        payload[:schema_version] = 2
        payload
      end
    end

    payload = base_payload.merge(schema_version: 1)
    expect { workflow_class.from_state(payload) }.to raise_error(Smith::PersistenceSchemaMismatch) do |err|
      expect(err.stored).to eq(2)
      expect(err.current).to eq(3)
    end
  end

  it "advances cursor defensively when a migration block forgets to set :schema_version" do
    workflow_class = Class.new(Smith::Workflow) do
      persistence_schema_version 2
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done

      migrate_from 1 do |payload|
        # Intentionally NOT setting :schema_version. Smith should still
        # terminate by advancing the cursor itself.
        payload[:context] = (payload[:context] || {}).merge(migrated: true)
        payload
      end
    end

    payload = base_payload.merge(schema_version: 1)
    workflow = workflow_class.from_state(payload)
    expect(workflow.instance_variable_get(:@context)[:migrated]).to be(true)
    expect(workflow.to_state[:schema_version]).to eq(2)
  end

  it "treats a pre-versioning payload (no schema_version key) as v1" do
    workflow_class = Class.new(Smith::Workflow) do
      persistence_schema_version 2
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done

      migrate_from 1 do |payload|
        payload[:schema_version] = 2
        payload[:context] = (payload[:context] || {}).merge(upgraded_from_legacy: true)
        payload
      end
    end

    payload_without_schema_key = base_payload.dup
    payload_without_schema_key.delete(:schema_version)

    workflow = workflow_class.from_state(payload_without_schema_key)
    expect(workflow.instance_variable_get(:@context)[:upgraded_from_legacy]).to be(true)
  end

  it "accepts JSON-parsed payloads with string keys (round-trips through JSON.generate)" do
    workflow_class = Class.new(Smith::Workflow) do
      persistence_schema_version 2
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done

      migrate_from 1 do |payload|
        payload[:schema_version] = 2
        payload[:context] = (payload[:context] || {}).merge(via_json: true)
        payload
      end
    end

    payload = JSON.parse(JSON.generate(base_payload.merge(schema_version: 1)))
    workflow = workflow_class.from_state(payload)
    expect(workflow.instance_variable_get(:@context)[:via_json]).to be(true)
  end

  it "propagates persistence_schema_version + migrations through class inheritance" do
    parent = Class.new(Smith::Workflow) do
      persistence_schema_version 2
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done

      migrate_from 1 do |payload|
        payload[:schema_version] = 2
        payload[:context] = (payload[:context] || {}).merge(from_parent: true)
        payload
      end
    end

    child = Class.new(parent)
    expect(child.persistence_schema_version).to eq(2)
    expect(child.migrations.keys).to include(1)

    payload = base_payload.merge(schema_version: 1)
    workflow = child.from_state(payload)
    expect(workflow.instance_variable_get(:@context)[:from_parent]).to be(true)
  end

  describe "DSL validation" do
    it "rejects non-positive persistence_schema_version" do
      expect {
        Class.new(Smith::Workflow) do
          persistence_schema_version 0
        end
      }.to raise_error(ArgumentError, /must be a positive Integer/)
    end

    it "rejects non-Integer persistence_schema_version" do
      expect {
        Class.new(Smith::Workflow) do
          persistence_schema_version "2"
        end
      }.to raise_error(ArgumentError, /must be a positive Integer/)
    end

    it "rejects migrate_from without a block" do
      expect {
        Class.new(Smith::Workflow) do
          migrate_from 1
        end
      }.to raise_error(ArgumentError, /requires a block/)
    end

    it "rejects migrate_from with a non-Integer version" do
      expect {
        Class.new(Smith::Workflow) do
          migrate_from "1" do |payload|
            payload
          end
        end
      }.to raise_error(ArgumentError, /must be a positive Integer/)
    end
  end
end
