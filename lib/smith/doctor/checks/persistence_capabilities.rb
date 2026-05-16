# frozen_string_literal: true

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

        OPTIONAL_CAPABILITIES = %i[store_versioned].freeze

        def run(report)
          adapter = resolve_adapter
          if adapter.nil?
            report.add(
              name: "persistence.capabilities",
              status: :warn,
              message: "No persistence adapter configured",
              detail: "Smith.config.persistence_adapter is nil and Smith.config.test_mode is false. " \
                      "Hosts using durable workflows must set persistence_adapter."
            )
            return
          end

          missing = OPTIONAL_CAPABILITIES.reject { |cap| Smith::PersistenceAdapters.supports?(adapter, cap) }

          if missing.empty?
            report.add(
              name: "persistence.capabilities",
              status: :pass,
              message: "#{adapter.class.name} supports all optional persistence capabilities",
              detail: "Supported: #{OPTIONAL_CAPABILITIES.join(', ')}"
            )
          else
            report.add(
              name: "persistence.capabilities",
              status: :warn,
              message: "#{adapter.class.name} missing optional capabilities: #{missing.join(', ')}",
              detail: "Workflows using these capabilities fall back to non-versioned writes " \
                      "with a one-time warning per adapter class. Switch to RedisStore, " \
                      "ActiveRecordStore (with lock_version column), or the Memory adapter " \
                      "for full coverage."
            )
          end
        end

        def resolve_adapter
          Smith.persistence_adapter
        rescue StandardError
          nil
        end
      end
    end
  end
end
