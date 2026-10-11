# frozen_string_literal: true

module Smith
  module Doctor
    module Checks
      # Whether an ActiveRecord persistence adapter's model can hold runs:
      # its locking column, a text payload, and a key the database keeps
      # unique. It reads schema metadata only; other adapters, and an
      # adapter configuration that does not resolve (Durability reports
      # it), are not checked.
      module StateModel
        module_function

        def run(report)
          adapter = active_record_adapter
          return unless adapter

          adapter.check_schema!
          report.add(name: "persistence.state_model", status: :pass,
                     message: "The workflow state model has a lock_version, a text payload and a unique key")
        rescue StandardError => e
          report.add(name: "persistence.state_model", status: :fail,
                     message: "The workflow state model cannot hold runs", detail: e.message)
        end

        def active_record_adapter
          return unless ::Smith.config.persistence_adapter

          adapter = ::Smith.persistence_adapter
          adapter if adapter.is_a?(::Smith::PersistenceAdapters::ActiveRecordStore)
        rescue StandardError
          nil
        end
      end
    end
  end
end
