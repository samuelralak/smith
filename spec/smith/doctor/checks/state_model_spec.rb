# frozen_string_literal: true

require "smith/doctor"

RSpec.describe Smith::Doctor::Checks::StateModel, :ar do
  around do |example|
    settings = %i[persistence_adapter persistence_options]
    original = settings.to_h { |name| [name, Smith.config.public_send(name)] }
    example.run
  ensure
    Smith.configure { |c| original.each { |name, value| c.public_send(:"#{name}=", value) } }
  end

  def checked(adapter, **options)
    Smith.configure do |c|
      c.persistence_adapter = adapter
      c.persistence_options = options
    end
    Smith::Doctor::Report.new.tap { described_class.run(_1) }.checks.to_h { [_1.name, _1] }
  end

  it "passes a model with a lock_version, a text payload and a unique key, in the default doctor run" do
    check = checked(:active_record, model: "SmithWorkflowStateRecord")["persistence.state_model"]
    names = Smith::Doctor.run(io: StringIO.new).checks.map(&:name)

    expect(check.status).to eq(:pass)
    expect(names).to include("persistence.state_model")
  end

  it "fails a model without a locking column or a key the database keeps unique" do
    stub_const("SpecUnlockedStateRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "smith_workflow_state_records"
      self.locking_column = :workflow_revision
    end)
    stub_const("SpecLooseKeyStateRecord", Class.new(ActiveRecord::Base) { self.table_name = "claimable_records" })

    unlocked = checked(:active_record, model: "SpecUnlockedStateRecord")["persistence.state_model"]
    loose = checked(:active_record, model: "SpecLooseKeyStateRecord", key_column: :status,
                                    payload_column: :status)["persistence.state_model"]
    expect([unlocked.status, unlocked.detail]).to match([:fail, /locking_column to be :lock_version/])
    expect([loose.status, loose.detail]).to match([:fail, /unique database index on claimable_records.status/])
  end

  it "fails a key column that is not a string, or too narrow for child runs' keys" do
    connection = ActiveRecord::Base.connection
    tables = { spec_narrow_key_states: [:string, { limit: 32 }], spec_number_key_states: [:integer, {}] }
    tables.each do |table, (type, options)|
      connection.create_table(table) do |t|
        t.column :key, type, null: false, index: { unique: true }, **options
        t.text :payload, null: false
        t.integer :lock_version, null: false, default: 0
      end
    end
    stub_const("SpecNarrowKeyState", Class.new(ActiveRecord::Base) { self.table_name = "spec_narrow_key_states" })
    stub_const("SpecNumberKeyState", Class.new(ActiveRecord::Base) { self.table_name = "spec_number_key_states" })

    %w[SpecNarrowKeyState SpecNumberKeyState].each do |model|
      check = checked(:active_record, model:)["persistence.state_model"]
      expect([check.status, check.detail]).to match([:fail, /string or text column of at least 64 characters/])
    end
  end

  it "skips the check when the database cannot be reached" do
    allow_any_instance_of(Smith::PersistenceAdapters::ActiveRecordStore)
      .to receive(:check_schema!).and_raise(ActiveRecord::NoDatabaseError)
    check = checked(:active_record, model: "SmithWorkflowStateRecord")["persistence.state_model"]

    expect([check.status, check.detail]).to eq([:skip, "ActiveRecord::NoDatabaseError"])
  end

  it "warns of an encrypted payload, which replace_exact refuses" do
    stub_const("SpecSealedStateRecord", Class.new(ActiveRecord::Base) do
      self.table_name = "smith_workflow_state_records"
      encrypts :payload
    end)
    checks = checked(:active_record, model: "SpecSealedStateRecord")
    adapter = Smith::PersistenceAdapters::ActiveRecordStore.new(model: SpecSealedStateRecord)

    expect(checks.values_at("persistence.state_model", "persistence.state_model.encryption").map(&:status))
      .to eq(%i[pass warn])
    expect { adapter.replace_exact("k", "{}", expected_payload: "{}") }
      .to raise_error(ArgumentError, /cannot use SpecSealedStateRecord's encrypted payload/)
    expect(Smith::PersistenceAdapters::ActiveRecordStore.new(model: SmithWorkflowStateRecord).encrypted_payload?)
      .to be(false)
  end

  it "checks nothing for another adapter, or one whose configuration does not resolve" do
    expect(checked(Smith::PersistenceAdapters::Memory.new)).to be_empty
    expect(checked(:cache_store)).to be_empty
    expect(checked(nil)).to be_empty
  end
end
