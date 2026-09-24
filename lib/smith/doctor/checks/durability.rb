# frozen_string_literal: true

require "json"

module Smith
  module Doctor
    module Checks
      module Durability
        PROBE_KEY = "smith_doctor_probe"

        def self.run(report)
          raw_adapter = ::Smith.config.persistence_adapter
          unless raw_adapter
            report.add(
              name: "durability.adapter",
              status: :warn,
              message: "No persistence adapter configured",
              detail: "Set config.persistence_adapter to :rails_cache, :active_record, :redis, :cache_store, or a custom adapter"
            )
            return
          end

          adapter = ::Smith.persistence_adapter
          add_backend_warning(report, adapter)
        rescue StandardError => e
          report.add(
            name: "durability.adapter",
            status: :fail,
            message: "Persistence adapter configuration is invalid",
            detail: e.message
          )
          return
        else
          check_ttl_support(report, adapter)
          check_persist_and_restore(report, adapter)
          check_resume_after_restore(report, adapter)
        end

        # ActiveRecordStore refuses every write that carries a TTL, so a
        # configured global TTL would fail the first persisted run.
        def self.check_ttl_support(report, adapter)
          ttl = ::Smith.config.persistence_ttl
          return if ttl.nil? || !adapter.is_a?(::Smith::PersistenceAdapters::ActiveRecordStore)

          report.add(
            name: "durability.ttl",
            status: :fail,
            message: "ActiveRecordStore cannot expire workflow state; persistence_ttl must be nil",
            detail: "Smith.config.persistence_ttl is #{ttl.inspect}, so every persisted write refuses it. " \
                    "Set it to nil, or use an adapter that honours TTL."
          )
        end

        def self.check_persist_and_restore(report, adapter)
          workflow_class = build_probe_class
          payload = JSON.generate(workflow_class.new.to_state)

          adapter.store(PROBE_KEY, payload)
          restored_payload = adapter.fetch(PROBE_KEY)
          restored = workflow_class.from_state(JSON.parse(restored_payload))
          adapter.delete(PROBE_KEY)

          valid = restored.state == :idle
          report.add(
            name: "durability.persist_restore",
            status: valid ? :pass : :fail,
            message: valid ? "Host persistence round-trip works" : "Host persistence round-trip failed"
          )
        rescue StandardError => e
          report.add(
            name: "durability.persist_restore", status: :fail,
            message: "Host persistence round-trip failed", detail: e.message
          )
        end

        def self.check_resume_after_restore(report, adapter)
          workflow_class = build_probe_class
          payload = JSON.generate(workflow_class.new.to_state)

          adapter.store(PROBE_KEY, payload)
          restored_payload = adapter.fetch(PROBE_KEY)
          restored = workflow_class.from_state(JSON.parse(restored_payload))
          adapter.delete(PROBE_KEY)

          result = restored.run!
          valid = result.state == :done

          report.add(
            name: "durability.resume_after_restore",
            status: valid ? :pass : :fail,
            message: valid ? "Restored workflow resumes correctly" : "Restored workflow did not reach terminal state"
          )
        rescue StandardError => e
          report.add(name: "durability.resume_after_restore", status: :fail,
                     message: "Resume after restore failed", detail: e.message)
        end

        def self.build_probe_class
          Class.new(::Smith::Workflow) do
            initial_state :idle
            state :done
            transition :finish, from: :idle, to: :done
          end
        end

        def self.add_backend_warning(report, adapter)
          warning = adapter.respond_to?(:durability_warning) ? adapter.durability_warning : nil
          return unless warning

          report.add(
            name: "durability.backend",
            status: :warn,
            message: warning
          )
        end
      end
    end
  end
end
