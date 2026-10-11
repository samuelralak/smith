# frozen_string_literal: true

require "tmpdir"

module Smith
  module Doctor
    module Checks
      # The artifact store: configured, buildable, usable, and as durable as
      # the workflow state, since a run that waits, retries or resumes in
      # another process reads its artifacts there.
      module Artifacts
        PROCESS_LOCAL = %w[Smith::Artifacts::Memory].freeze
        COLUMNS = %w[ref data content_type execution_namespace created_at].freeze

        def self.run(report)
          raw = ::Smith.config.artifact_store
          return report.add(**missing) if raw.nil? && !::Smith.config.test_mode

          store = ::Smith.artifact_backend
          report.add(name: "artifacts.store", status: :pass, message: "Artifact store: #{store_name(store)}")
          check_usable(report, store)
          check_durability(report, store)
          check_ownership(report, store)
        rescue StandardError => e
          report.add(name: "artifacts.store", status: :fail, message: "Artifact store configuration is invalid",
                     detail: e.message)
        end

        def self.store_name(store) = store.is_a?(Module) ? store.name : store.class.name

        def self.missing
          { name: "artifacts.store", status: :warn, message: "No artifact store configured",
            detail: "Set config.artifact_store to :s3 (S3, R2), :active_record, :file, or a store, with " \
                    "config.artifact_options; steps that store artifacts or read documents fail without one" }
        end

        # The table an Active Record store writes, the directory a File
        # store writes, the bucket an S3 store writes.
        def self.check_usable(report, store)
          problem = case store
                    when ::Smith::Artifacts::ActiveRecordStore then table_problem(store)
                    when ::Smith::Artifacts::File then directory_problem(store)
                    when ::Smith::Artifacts::S3 then bucket_problem(store)
                    end
          return unless problem

          report.add(name: "artifacts.usable", status: :warn, message: "The artifact store cannot be used",
                     detail: problem)
        end

        def self.table_problem(store)
          missing = COLUMNS - store.model.column_names
          "#{store.model.name} lacks the columns #{missing.join(", ")}" if missing.any?
        rescue StandardError => e
          "the store's model cannot be loaded: #{e.message}"
        end

        def self.directory_problem(store)
          dir = store.instance_variable_get(:@dir)
          "the directory #{dir} is not writable" unless ::File.directory?(dir) && ::File.writable?(dir)
        end

        def self.bucket_problem(store)
          client = store.instance_variable_get(:@client)
          return unless client.respond_to?(:head_bucket)

          client.head_bucket(bucket: store.instance_variable_get(:@bucket))
          nil
        rescue StandardError => e
          "the bucket cannot be reached: #{e.class.name}"
        end

        def self.check_durability(report, store)
          adapter = ::Smith.config.persistence_adapter
          return unless PROCESS_LOCAL.include?(store.class.name) && adapter && !process_local_state?(adapter)

          report.add(
            name: "artifacts.durability", status: :warn,
            message: "Artifacts are kept in process memory while workflow state is persisted",
            detail: "A run that waits, retries or resumes in another process loses its artifacts; configure :s3, " \
                    ":active_record or :file"
          )
        end

        def self.process_local_state?(adapter)
          adapter.to_s == "memory" || adapter.is_a?(::Smith::PersistenceAdapters::Memory)
        end

        def self.check_ownership(report, store)
          return if store.respond_to?(:stored_by?)

          report.add(
            name: "artifacts.ownership", status: :warn,
            message: "The artifact store cannot tell which run stored a ref (stored_by?)",
            detail: "Runs read any ref under their prefix, and content parts cannot read documents from it"
          )
        end
        private_class_method :store_name, :missing, :check_usable, :table_problem, :directory_problem, :bucket_problem,
                             :check_durability, :process_local_state?, :check_ownership
      end
    end
  end
end
