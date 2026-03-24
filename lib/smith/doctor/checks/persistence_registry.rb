# frozen_string_literal: true

module Smith
  module Doctor
    module Checks
      module PersistenceRegistry
        def self.check(report, mode)
          case mode
          when :database
            check_database_registry(report)
          when :bundled
            report.add(name: "persistence.model_registry_mode", status: :pass,
                       message: "Model registry mode: bundled (explicit)")
          else
            report.add(
              name: "persistence.model_registry_mode", status: :pass,
              message: "Model registry mode: bundled fallback (default)",
              detail: "Set config.ruby_llm_model_registry = :database if DB-backed registry is required"
            )
          end
        end

        def self.check_database_registry(report)
          registry_class = resolve_registry_class
          unless registry_class
            report.add(name: "persistence.model_registry_mode", status: :fail,
                       message: "DB-backed model registry required but registry class not resolvable",
                       detail: "RubyLLM.config.model_registry_class could not be resolved to a constant")
            return
          end

          unless ar_backed?(registry_class)
            report.add(name: "persistence.model_registry_mode", status: :fail,
                       message: "DB-backed model registry required but class is not ActiveRecord-backed",
                       detail: "#{registry_class.name} does not inherit from ActiveRecord::Base")
            return
          end

          verify_registry_table_and_records(report, registry_class)
        end

        def self.resolve_registry_class
          raw = ::RubyLLM.config.model_registry_class
          return nil unless raw

          klass = raw.is_a?(String) ? Object.const_get(raw) : raw
          klass.is_a?(Class) ? klass : nil
        rescue NameError
          nil
        end

        def self.ar_backed?(klass)
          klass.ancestors.any? { |a| a.name&.include?("ActiveRecord::Base") }
        rescue StandardError
          false
        end

        def self.verify_registry_table_and_records(report, registry_class)
          unless registry_class.table_exists?
            report.add(name: "persistence.model_registry_mode", status: :fail,
                       message: "DB-backed model registry table missing",
                       detail: "#{registry_class.table_name} does not exist")
            return
          end

          count = registry_class.count
          if count.positive?
            report.add(name: "persistence.model_registry_mode", status: :pass,
                       message: "DB-backed model registry operational (#{count} records)")
          else
            report.add(name: "persistence.model_registry_mode", status: :fail,
                       message: "DB-backed model registry table exists but is empty",
                       detail: "Run ruby_llm model sync or seeding task")
          end
        rescue StandardError => e
          report.add(name: "persistence.model_registry_mode", status: :fail,
                     message: "DB-backed model registry query failed", detail: e.message)
        end
      end
    end
  end
end
