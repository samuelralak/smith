# frozen_string_literal: true

begin
  require "active_record"
  require "sqlite3"
rescue LoadError => e
  raise "Active Record specs require the development and test bundle: #{e.message}"
end

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

ActiveRecord::Schema.define do
  self.verbose = false
  create_table :claimable_records do |t|
    t.string :status, null: false
    t.integer :lock_version, null: false, default: 0
    t.timestamps
  end

  create_table :smith_workflow_state_records do |t|
    t.string :key, null: false, index: { unique: true }
    t.text :payload, null: false
    t.integer :lock_version, null: false, default: 0
    t.integer :workflow_revision, null: false, default: 0
    t.string :unique_token
    t.timestamps
  end
  add_index :smith_workflow_state_records, :unique_token, unique: true
end

class ClaimableRecord < ActiveRecord::Base
  def mark_processing!
    update_columns(status: "processing", updated_at: Time.now.utc)
  end

  def mark_ready!
    update_columns(status: "ready", updated_at: Time.now.utc)
  end
end

RSpec.configure do |config|
  config.around(:each, :ar) do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end
