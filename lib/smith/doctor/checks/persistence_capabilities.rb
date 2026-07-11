# frozen_string_literal: true

require_relative "../../persistence_adapters"

module Smith
  module Doctor
    module Checks
      # Reports which optional capabilities the configured persistence
      # adapter supports. Hosts who depend on optimistic locking but
      # configure a cache-backed adapter (CacheStore / RailsCache) need
      # to know up front that store_versioned silently falls back to
      # plain store. Workflow#persist! warns once per adapter class
      # per Smith boot, but doctor surfaces it eagerly.
      module PersistenceCapabilities
        module_function

        OPTIONAL_CAPABILITIES = Smith::PersistenceAdapters::OPTIONAL_METHODS

        def run(report)
          adapter = resolve_adapter
          return report_missing_adapter(report) if adapter.nil?

          missing = OPTIONAL_CAPABILITIES.reject { |cap| Smith::PersistenceAdapters.supports?(adapter, cap) }
          return report_supported_capabilities(report, adapter) if missing.empty?

          report_missing_capabilities(report, adapter, missing)
        end

        def resolve_adapter
          Smith.persistence_adapter
        rescue StandardError
          nil
        end

        def report_missing_adapter(report)
          report.add(
            name: "persistence.capabilities",
            status: :warn,
            message: "No persistence adapter configured",
            detail: "Smith.config.persistence_adapter is nil and Smith.config.test_mode is false. " \
                    "Hosts using durable workflows must set persistence_adapter."
          )
        end

        def report_supported_capabilities(report, adapter)
          report.add(
            name: "persistence.capabilities",
            status: :pass,
            message: "#{adapter.class.name} supports all optional persistence capabilities",
            detail: "Supported: #{OPTIONAL_CAPABILITIES.join(", ")}"
          )
        end

        def report_missing_capabilities(report, adapter, missing)
          report.add(
            name: "persistence.capabilities",
            status: :warn,
            message: "#{adapter.class.name} missing optional capabilities: #{missing.join(", ")}",
            detail: "Smith will fall back where possible: non-versioned writes when store_versioned " \
                    "is missing, and payload updated_at parsing when heartbeat methods are missing. " \
                    "Without transaction_open?, commit-aware split-step confirmation is unavailable. " \
                    "Use RedisStore or Memory for full versioning and heartbeat coverage; " \
                    "ActiveRecordStore currently covers optimistic locking when lock_version is present."
          )
        end
      end
    end
  end
end
