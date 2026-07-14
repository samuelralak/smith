# frozen_string_literal: true

RSpec.describe Smith::PersistenceAdapters::ActiveRecordStore, :ar do
  subject(:adapter) { described_class.new(model: SmithWorkflowStateRecord) }

  before do
    SmithWorkflowStateRecord.delete_all
  end

  it "keeps Smith payload versions aligned across consecutive writes" do
    expect(adapter.store_versioned("workflow-1", payload(1), expected_version: 0)).to eq(true)

    first = SmithWorkflowStateRecord.find_by!(key: "workflow-1")
    expect(stored_version(first)).to eq(1)
    expect(first.lock_version).to eq(0)

    expect(adapter.store_versioned("workflow-1", payload(2), expected_version: 1)).to eq(true)

    second = SmithWorkflowStateRecord.find_by!(key: "workflow-1")
    expect(stored_version(second)).to eq(2)
    expect(second.lock_version).to eq(1)
  end

  it "atomically replaces only the exact current payload" do
    original = payload(1).sub("}", ',"phase":"prepared"}')
    claimed = payload(1).sub("}", ',"phase":"dispatching"}')
    adapter.store_versioned("exact", original, expected_version: 0)

    expect(adapter.replace_exact("exact", claimed, expected_payload: original, ttl: nil)).to eq(claimed)

    record = SmithWorkflowStateRecord.find_by!(key: "exact")
    expect(record.payload).to eq(claimed)
    expect(record.lock_version).to eq(1)
  end

  it "rejects same-version payload mutation during exact replacement" do
    original = payload(1).sub("}", ',"phase":"prepared"}')
    mutated = payload(1).sub("}", ',"phase":"mutated"}')
    claimed = payload(1).sub("}", ',"phase":"dispatching"}')
    SmithWorkflowStateRecord.create!(key: "exact", payload: mutated)

    expect do
      adapter.replace_exact("exact", claimed, expected_payload: original, ttl: nil)
    end.to raise_error(Smith::PersistencePayloadConflict)
    expect(SmithWorkflowStateRecord.find_by!(key: "exact").payload).to eq(mutated)
  end

  it "rejects a second exact replacement after the first claim" do
    original = payload(1).sub("}", ',"phase":"prepared"}')
    claimed = payload(1).sub("}", ',"phase":"dispatching"}')
    adapter.store_versioned("exact", original, expected_version: 0)
    adapter.replace_exact("exact", claimed, expected_payload: original, ttl: nil)

    expect do
      adapter.replace_exact("exact", claimed, expected_payload: original, ttl: nil)
    end.to raise_error(Smith::PersistencePayloadConflict)
  end

  it "compares the expected payload in the atomic database update" do
    original = payload(1).sub("}", ',"phase":"prepared"}')
    claimed = payload(1).sub("}", ',"phase":"dispatching"}')
    adapter.store_versioned("exact", original, expected_version: 0)
    SmithWorkflowStateRecord.where(key: "exact").update_all(payload: payload(1).sub("}", ',"phase":"bypassed"}'))

    expect do
      adapter.replace_exact("exact", claimed, expected_payload: original, ttl: nil)
    end.to raise_error(Smith::PersistencePayloadConflict)
    expect(SmithWorkflowStateRecord.find_by!(key: "exact").payload).to include('"phase":"bypassed"')
  end

  it "compares payload bytes independently of the database collation" do
    with_exact_store_model(:smith_collated_workflow_states, unique: true, collation: "NOCASE") do |model|
      stored = '{"phase":"PREPARED"}'
      expected = '{"phase":"prepared"}'
      model.create!(key: "exact", payload: stored)
      collated_adapter = described_class.new(model: model, identity: "collated")

      expect do
        collated_adapter.replace_exact("exact", '{"phase":"dispatching"}', expected_payload: expected, ttl: nil)
      end.to raise_error(Smith::PersistencePayloadConflict)
      expect(model.find_by!(key: "exact").payload).to eq(stored)
    end
  end

  it "rejects a non-unique key schema before mutating duplicate rows" do
    with_exact_store_model(:smith_duplicate_workflow_states, unique: false) do |model|
      2.times { model.create!(key: "duplicate", payload: '{"phase":"prepared"}') }
      duplicate_adapter = described_class.new(model: model, identity: "duplicates")

      expect do
        duplicate_adapter.replace_exact(
          "duplicate",
          '{"phase":"dispatching"}',
          expected_payload: '{"phase":"prepared"}',
          ttl: nil
        )
      end.to raise_error(ArgumentError, /unique database index/)
      expect(model.where(key: "duplicate").pluck(:payload, :lock_version)).to eq(
        Array.new(2) { ['{"phase":"prepared"}', 0] }
      )
    end
  end

  it "does not trust a model-level primary key declaration without a database constraint" do
    with_exact_store_model(:smith_spoofed_primary_states, unique: false) do |model|
      model.primary_key = "key"
      2.times { model.create!(key: "duplicate", payload: '{"phase":"prepared"}') }
      spoofed_adapter = described_class.new(model: model, identity: "spoofed-primary")

      expect do
        spoofed_adapter.replace_exact(
          "duplicate",
          '{"phase":"dispatching"}',
          expected_payload: '{"phase":"prepared"}'
        )
      end.to raise_error(ArgumentError, /unique database index/)
      expect(model.where(key: "duplicate").distinct.pluck(:payload)).to eq(['{"phase":"prepared"}'])
    end
  end

  it "does not treat a partial unique index as global key uniqueness" do
    with_exact_store_model(:smith_partial_unique_states, unique: false, active: true) do |model|
      model.connection.add_index(model.table_name, :key, unique: true, where: "active = 1")
      2.times { model.create!(key: "duplicate", payload: '{"phase":"prepared"}', active: false) }
      partial_adapter = described_class.new(model: model, identity: "partial-index")

      expect do
        partial_adapter.replace_exact(
          "duplicate",
          '{"phase":"dispatching"}',
          expected_payload: '{"phase":"prepared"}'
        )
      end.to raise_error(ArgumentError, /unique database index/)
      expect(model.where(key: "duplicate").distinct.pluck(:payload)).to eq(['{"phase":"prepared"}'])
    end
  end

  it "ignores unrelated expression indexes while validating a unique key" do
    with_exact_store_model(:smith_expression_index_states, unique: true) do |model|
      model.connection.execute(
        "CREATE UNIQUE INDEX index_smith_expression_payload " \
        "ON smith_expression_index_states (lower(payload))"
      )
      model.create!(key: "exact", payload: '{"phase":"prepared"}')
      expression_adapter = described_class.new(model: model, identity: "expression-index")

      expect(
        expression_adapter.replace_exact(
          "exact",
          '{"phase":"dispatching"}',
          expected_payload: '{"phase":"prepared"}'
        )
      ).to eq('{"phase":"dispatching"}')
    end
  end

  it "revalidates schema metadata when one model changes tables" do
    with_exact_store_model(:smith_unique_swap_states, unique: true) do |model|
      swap_adapter = described_class.new(model: model, identity: "table-swap")
      model.create!(key: "unique", payload: '{"phase":"prepared"}')
      swap_adapter.replace_exact("unique", '{"phase":"dispatching"}', expected_payload: '{"phase":"prepared"}')

      with_exact_store_model(:smith_duplicate_swap_states, unique: false) do |duplicate_model|
        model.table_name = duplicate_model.table_name
        model.reset_column_information
        2.times { model.create!(key: "duplicate", payload: '{"phase":"prepared"}') }

        expect do
          swap_adapter.replace_exact(
            "duplicate",
            '{"phase":"dispatching"}',
            expected_payload: '{"phase":"prepared"}'
          )
        end.to raise_error(ArgumentError, /unique database index/)
        expect(model.where(key: "duplicate").distinct.pluck(:payload)).to eq(['{"phase":"prepared"}'])
      end
    end
  end

  it "rejects representation-normalizing payload columns before mutation" do
    with_exact_store_model(:smith_json_workflow_states, unique: true, payload_type: :json) do |model|
      model.create!(key: "exact", payload: { "phase" => "prepared" })
      json_adapter = described_class.new(model: model, identity: "json")

      expect do
        json_adapter.replace_exact("exact", '{"phase":"dispatching"}', expected_payload: '{"phase":"prepared"}')
      end.to raise_error(ArgumentError, /text or string payload column/)
      expect(model.find_by!(key: "exact").payload).to eq("phase" => "prepared")
    end
  end

  it "pins an explicit persistence identity without deriving infrastructure secrets" do
    identity = +"primary:workflow-states"
    configured = described_class.new(model: SmithWorkflowStateRecord, identity: identity)
    identity.replace("changed")

    expect(configured.persistence_identity).to eq("primary:workflow-states")
    expect(configured.persistence_identity).to be_frozen
  end

  it "pins mutable column configuration at initialization" do
    key_column = +"key"
    payload_column = +"payload"
    version_column = +"lock_version"
    configured = described_class.new(
      model: SmithWorkflowStateRecord,
      key_column: key_column,
      payload_column: payload_column,
      version_column: version_column
    )
    key_column.replace("changed_key")
    payload_column.replace("changed_payload")
    version_column.replace("changed_version")

    expect(configured.store_versioned("pinned", payload(1), expected_version: 0)).to eq(true)
    expect(SmithWorkflowStateRecord).to exist(key: "pinned")
  end

  it "rejects a stale Smith payload version with the stored logical version" do
    adapter.store_versioned("workflow-1", payload(1), expected_version: 0)

    expect do
      adapter.store_versioned("workflow-1", payload(2), expected_version: 0)
    end.to raise_error(Smith::PersistenceVersionConflict) { |error|
      expect(error.expected).to eq(0)
      expect(error.actual).to eq(1)
    }
  end

  it "uses Active Record optimistic locking for concurrent row updates" do
    adapter.store_versioned("workflow-1", payload(1), expected_version: 0)
    stale_record = SmithWorkflowStateRecord.find_by!(key: "workflow-1")
    SmithWorkflowStateRecord.find_by!(key: "workflow-1").update!(payload: payload(2))
    allow(SmithWorkflowStateRecord).to receive(:find_by).and_return(stale_record)

    expect do
      adapter.store_versioned("workflow-1", payload(2), expected_version: 1)
    end.to raise_error(Smith::PersistenceVersionConflict) { |error|
      expect(error.expected).to eq(1)
      expect(error.actual).to eq(:concurrent)
    }
  end

  it "contains a concurrent initial insert and reports a version conflict" do
    SmithWorkflowStateRecord.create!(key: "workflow-1", payload: payload(1))
    force_initial_miss(SmithWorkflowStateRecord)

    SmithWorkflowStateRecord.transaction(requires_new: true) do
      expect do
        adapter.store_versioned("workflow-1", payload(1), expected_version: 0)
      end.to raise_error(Smith::PersistenceVersionConflict) { |error|
        expect(error.expected).to eq(0)
        expect(error.actual).to eq(:concurrent)
      }

      SmithWorkflowStateRecord.create!(key: "transaction-usable", payload: payload(1))
    end

    expect(SmithWorkflowStateRecord).to exist(key: "transaction-usable")
  end

  it "translates a key uniqueness validation into a concurrent conflict" do
    validated_model = stub_const(
      "SmithValidatedWorkflowStateRecord",
      Class.new(SmithWorkflowStateRecord) { validates :key, uniqueness: true }
    )
    validated_model.create!(key: "workflow-1", payload: payload(1))
    validated_adapter = described_class.new(model: validated_model)
    force_initial_miss(validated_model)

    expect do
      validated_adapter.store_versioned("workflow-1", payload(1), expected_version: 0)
    end.to raise_error(Smith::PersistenceVersionConflict) { |error|
      expect(error.actual).to eq(:concurrent)
    }
  end

  it "does not misreport a different unique constraint as a key conflict" do
    constrained_model = Class.new(SmithWorkflowStateRecord) do
      before_validation { self.unique_token = "shared" }
    end
    constrained_model.create!(key: "workflow-1", payload: payload(1))
    constrained_adapter = described_class.new(model: constrained_model)

    expect do
      constrained_adapter.store_versioned("workflow-2", payload(1), expected_version: 0)
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "preserves a host callback rollback during initial creation" do
    rollback_model = Class.new(SmithWorkflowStateRecord) do
      after_create { raise ActiveRecord::Rollback }
    end
    rollback_adapter = described_class.new(model: rollback_model)

    expect do
      rollback_adapter.store_versioned("workflow-1", payload(1), expected_version: 0)
    end.to raise_error(ActiveRecord::RecordNotSaved)
    expect(rollback_model).not_to exist(key: "workflow-1")
  end

  it "recognizes a successful insert even when a host callback reloads the record" do
    reload_model = Class.new(SmithWorkflowStateRecord) do
      after_create(&:reload)
    end
    reload_adapter = described_class.new(model: reload_model)

    expect(reload_adapter.store_versioned("workflow-1", payload(1), expected_version: 0)).to eq(true)
    expect(reload_model).to exist(key: "workflow-1")
  end

  it "treats legacy or malformed payloads as version zero" do
    SmithWorkflowStateRecord.create!(key: "legacy", payload: "not-json")

    adapter.store_versioned("legacy", payload(1), expected_version: 0)

    record = SmithWorkflowStateRecord.find_by!(key: "legacy")
    expect(stored_version(record)).to eq(1)
    expect(record.lock_version).to eq(1)
  end

  it "fails closed on a valid JSON payload that is not an object" do
    SmithWorkflowStateRecord.create!(key: "scalar", payload: "null")

    expect do
      adapter.store_versioned("scalar", payload(1), expected_version: 0)
    end.to raise_error(TypeError, /payload must be a JSON object/)
  end

  it "fails closed on an explicitly invalid payload version" do
    SmithWorkflowStateRecord.create!(key: "invalid", payload: '{"persistence_version":null}')

    expect do
      adapter.store_versioned("invalid", payload(1), expected_version: 0)
    end.to raise_error(TypeError, /persistence_version must be a non-negative integer/)
  end

  it "participates in an outer Active Record transaction" do
    adapter.store_versioned("workflow-1", payload(1), expected_version: 0)

    SmithWorkflowStateRecord.transaction(requires_new: true) do
      adapter.store_versioned("workflow-1", payload(2), expected_version: 1)
      raise ActiveRecord::Rollback
    end

    record = SmithWorkflowStateRecord.find_by!(key: "workflow-1")
    expect(stored_version(record)).to eq(1)
    expect(record.lock_version).to eq(0)
  end

  it "coordinates a restart-safe dispatch claim with a host transaction", :commit do
    digest = Digest::SHA256.hexdigest("active-record-dispatch-workflow-v1")
    workflow_class = stub_const("SpecActiveRecordDispatchWorkflow", Class.new(Smith::Workflow) do
      definition_digest digest
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end)
    durable_adapter = described_class.new(
      model: SmithWorkflowStateRecord,
      identity: "spec:workflow-states"
    )
    workflow = workflow_class.new
    key = "transactional-dispatch"

    SmithWorkflowStateRecord.transaction do
      workflow.prepare_persisted_step!(key, adapter: durable_adapter)
    end
    workflow.confirm_prepared_step!
    prepared_payload = durable_adapter.fetch(key)

    SmithWorkflowStateRecord.transaction do
      workflow.claim_prepared_step_dispatch!
      expect(JSON.parse(durable_adapter.fetch(key))).to include("split_step_phase" => "dispatching")
      raise ActiveRecord::Rollback
    end

    expect(durable_adapter.fetch(key)).to eq(prepared_payload)
    expect do
      workflow.confirm_prepared_step_dispatch!
    end.to raise_error(Smith::WorkflowError, /not committed/)

    workflow.claim_prepared_step_dispatch!
    expect(workflow.execute_prepared_step!).to include(transition: :finish, to: :done)
  end

  it "reports whether its model connection has an open transaction", :commit do
    expect(adapter.transaction_open?).to be(false)
    expect(adapter.transaction_identity).to be_nil

    SmithWorkflowStateRecord.transaction do
      expect(adapter.transaction_open?).to be(true)
      identity = adapter.transaction_identity
      expect(identity).to match(Smith::Workflow::PreparedStep::UUID_PATTERN)
      expect(adapter.transaction_identity).to eq(identity)

      SmithWorkflowStateRecord.transaction(requires_new: true) do
        expect(adapter.transaction_identity).not_to eq(identity)
      end

      expect(adapter.transaction_identity).to eq(identity)
    end

    expect(adapter.transaction_open?).to be(false)
    expect(adapter.transaction_identity).to be_nil
  end

  it "supports consecutive workflow persist and stale restore rejection" do
    workflow_class = Class.new(Smith::Workflow) do
      initial_state :pending
      state :done
    end
    writer = workflow_class.new
    writer.persist!("workflow-1", adapter: adapter)
    first_reader = workflow_class.restore("workflow-1", adapter: adapter)
    stale_reader = workflow_class.restore("workflow-1", adapter: adapter)

    first_reader.persist!("workflow-1", adapter: adapter)

    expect do
      stale_reader.persist!("workflow-1", adapter: adapter)
    end.to raise_error(Smith::PersistenceVersionConflict) { |error|
      expect(error.expected).to eq(1)
      expect(error.actual).to eq(2)
    }
    expect(stale_reader.to_state.fetch(:persistence_version)).to eq(1)
  end

  it "supports a host model with a custom Active Record locking column" do
    custom_model = Class.new(SmithWorkflowStateRecord) do
      self.locking_column = :workflow_revision
    end
    custom_adapter = described_class.new(
      model: custom_model,
      version_column: :workflow_revision
    )

    custom_adapter.store_versioned("workflow-1", payload(1), expected_version: 0)
    custom_adapter.store_versioned("workflow-1", payload(2), expected_version: 1)

    record = custom_model.find_by!(key: "workflow-1")
    expect(stored_version(record)).to eq(2)
    expect(record.workflow_revision).to eq(1)
    expect(record.lock_version).to eq(0)
  end

  it "fails closed when the configured version column is not the model locking column" do
    misconfigured = described_class.new(
      model: SmithWorkflowStateRecord,
      version_column: :workflow_revision
    )

    expect do
      misconfigured.store_versioned("workflow-1", payload(1), expected_version: 0)
    end.to raise_error(ArgumentError, /locking_column.*workflow_revision/)
  end

  it "fails closed when optimistic locking is disabled on the host model" do
    unlocked_model = Class.new(SmithWorkflowStateRecord) do
      self.lock_optimistically = false
    end
    unlocked_adapter = described_class.new(model: unlocked_model)

    expect do
      unlocked_adapter.store_versioned("workflow-1", payload(1), expected_version: 0)
    end.to raise_error(ArgumentError, /optimistic locking enabled/)
  end

  it "translates a connection failure without replaying the versioned write" do
    allow(SmithWorkflowStateRecord).to receive(:find_by).and_raise(ActiveRecord::ConnectionFailed, "lost")

    expect do
      adapter.store_versioned("workflow-1", payload(1), expected_version: 0)
    end.to raise_error(Smith::PersistenceIOError) { |error|
      expect(error.cause).to be_a(ActiveRecord::ConnectionFailed)
    }
    expect(SmithWorkflowStateRecord).to have_received(:find_by).once
    expect(Smith::PersistenceAdapters::ActiveRecordConnectionErrors.classes).to include(
      ActiveRecord::ConnectionNotEstablished,
      ActiveRecord::ConnectionFailed,
      ActiveRecord::AdapterTimeout
    )
  end

  it "resolves a string model source again after a host reload" do
    original = Class.new(SmithWorkflowStateRecord)
    Object.const_set(:SmithReloadableWorkflowStateRecord, original)
    reloadable_adapter = described_class.new(model: "SmithReloadableWorkflowStateRecord")
    expect(reloadable_adapter.send(:model_class)).to equal(original)

    Object.send(:remove_const, :SmithReloadableWorkflowStateRecord)
    replacement = Class.new(SmithWorkflowStateRecord)
    Object.const_set(:SmithReloadableWorkflowStateRecord, replacement)

    expect(reloadable_adapter.send(:model_class)).to equal(replacement)
  ensure
    Object.send(:remove_const, :SmithReloadableWorkflowStateRecord) if
      Object.const_defined?(:SmithReloadableWorkflowStateRecord, false)
  end

  def payload(version)
    JSON.generate("persistence_version" => version)
  end

  def stored_version(record)
    JSON.parse(record.payload).fetch("persistence_version")
  end

  def force_initial_miss(model)
    first_lookup = true
    allow(model).to receive(:find_by).and_wrap_original do |original, *args|
      if first_lookup
        first_lookup = false
        nil
      else
        original.call(*args)
      end
    end
  end

  def with_exact_store_model(table_name, unique:, collation: nil, payload_type: :text, active: false)
    connection = ActiveRecord::Base.connection
    connection.create_table(table_name) do |table|
      table.string :key, null: false
      table.public_send(payload_type, :payload, null: false, collation: collation)
      table.integer :lock_version, null: false, default: 0
      table.boolean :active, null: false, default: true if active
    end
    connection.add_index(table_name, :key, unique: true) if unique
    model = Class.new(ActiveRecord::Base)
    model.table_name = table_name.to_s
    yield model
  ensure
    connection&.drop_table(table_name, if_exists: true)
  end

  it "does not recreate missing state from a nonzero expected version" do
    expect do
      adapter.store_versioned("missing", payload(3), expected_version: 2)
    end.to raise_error(Smith::PersistenceVersionConflict) { |error|
      expect(error.expected).to eq(2)
      expect(error.actual).to eq(:missing)
    }
    expect(SmithWorkflowStateRecord).not_to exist(key: "missing")
  end

  it "does not misattribute a callback's stale related record to the workflow row" do
    related_record = SmithWorkflowStateRecord.new
    callback_model = Class.new(SmithWorkflowStateRecord) do
      after_update { raise ActiveRecord::StaleObjectError.new(related_record, "update") }
    end
    callback_adapter = described_class.new(model: callback_model)
    callback_adapter.store_versioned("workflow-1", payload(1), expected_version: 0)

    expect do
      callback_adapter.store_versioned("workflow-1", payload(2), expected_version: 1)
    end.to raise_error(ActiveRecord::StaleObjectError) { |error|
      expect(error.record).to equal(related_record)
    }
    expect(stored_version(callback_model.find_by!(key: "workflow-1"))).to eq(2)
  end
end
