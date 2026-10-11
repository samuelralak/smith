# frozen_string_literal: true

module Smith
  module Doctor
    module Checks
      # Whether an ActiveRecord persistence adapter's model can hold runs:
      # its locking column, a text payload, and a string key the database
      # keeps unique. It reads schema metadata only, and skips when the
      # database cannot be reached (the default doctor run is offline).
      # Other adapters, and an adapter configuration that does not resolve
      # (Durability reports it), are not checked.
      module StateModel
        NAME = "persistence.state_model"

        module_function

        def run(report)
          adapter = active_record_adapter
          return unless adapter

          adapter.check_schema!
          report.add(name: NAME, status: :pass,
                     message: "The workflow state model has a lock_version, a text payload and a unique key")
          report_encryption(report) if adapter.encrypted_payload?
        rescue StandardError => e
          report_failure(report, e)
        end

        def report_failure(report, error)
          if unreachable?(error)
            report.add(name: NAME, status: :skip, detail: error.class.name,
                       message: "The workflow state model was not checked: the database could not be reached")
          else
            report.add(name: NAME, status: :fail, message: "The workflow state model cannot hold runs",
                       detail: error.message)
          end
        end

        def report_encryption(report)
          report.add(name: "#{NAME}.encryption", status: :warn,
                     message: "The workflow state payload is encrypted",
                     detail: "Runs store and read it, but split-step exact writes (replace_exact) compare " \
                             "payloads in the database and cannot use an encrypted one")
        end

        def unreachable?(error)
          classes = PersistenceAdapters::ActiveRecordConnectionErrors.classes
          classes << ::ActiveRecord::NoDatabaseError if defined?(::ActiveRecord::NoDatabaseError)
          classes.any? { error.is_a?(_1) }
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
