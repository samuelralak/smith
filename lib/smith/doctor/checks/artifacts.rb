# frozen_string_literal: true

module Smith
  module Doctor
    module Checks
      # The artifact store: configured, buildable, and as durable as the
      # workflow state, since a run that waits, retries or resumes in
      # another process reads its artifacts there.
      module Artifacts
        PROCESS_LOCAL = %w[Smith::Artifacts::Memory].freeze

        def self.run(report)
          raw = ::Smith.config.artifact_store
          return report.add(**missing) if raw.nil? && !::Smith.config.test_mode

          store = ::Smith.artifact_backend
          report.add(name: "artifacts.store", status: :pass, message: "Artifact store: #{store.class.name}")
          check_durability(report, store)
          check_ownership(report, store)
        rescue StandardError => e
          report.add(name: "artifacts.store", status: :fail, message: "Artifact store configuration is invalid",
                     detail: e.message)
        end

        def self.missing
          { name: "artifacts.store", status: :warn, message: "No artifact store configured",
            detail: "Set config.artifact_store to :s3 (S3, R2), :active_record, :file, or a store, with " \
                    "config.artifact_options; steps that store artifacts or read documents fail without one" }
        end

        def self.check_durability(report, store)
          return unless PROCESS_LOCAL.include?(store.class.name) && ::Smith.config.persistence_adapter

          report.add(
            name: "artifacts.durability", status: :warn,
            message: "Artifacts are kept in process memory while workflow state is persisted",
            detail: "A run that waits, retries or resumes in another process loses its artifacts; configure :s3, " \
                    ":active_record or :file"
          )
        end

        def self.check_ownership(report, store)
          return if store.respond_to?(:stored_by?)

          report.add(
            name: "artifacts.ownership", status: :warn,
            message: "The artifact store cannot tell which run stored a ref (stored_by?)",
            detail: "Runs read any ref under their prefix, and content parts cannot read documents from it"
          )
        end
        private_class_method :missing, :check_durability, :check_ownership
      end
    end
  end
end
