# frozen_string_literal: true

# ENV-gated ActiveRecord + sqlite3 harness for specs tagged :ar.
# Default behavior (SMITH_AR_SPECS unset): :ar examples are excluded
# from the suite so the existing spec set runs without loading AR or
# ActiveSupport monkey-patches. Opt in with SMITH_AR_SPECS=1.

if ENV["SMITH_AR_SPECS"]
  begin
    require "active_record"
    require "sqlite3"
  rescue LoadError => e
    raise "SMITH_AR_SPECS=#{ENV['SMITH_AR_SPECS']} but #{e.message}. Bundle install with the development group."
  end

  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

  ActiveRecord::Schema.define do
    self.verbose = false
    create_table :claimable_records do |t|
      t.string :status, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
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
else
  RSpec.configure do |config|
    config.filter_run_excluding(:ar)
  end
end
