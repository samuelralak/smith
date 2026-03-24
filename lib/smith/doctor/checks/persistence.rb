# frozen_string_literal: true

require_relative "persistence_registry"

module Smith
  module Doctor
    module Checks
      module Persistence
        def self.run(report)
          check_active_record(report)
          check_db_connection(report)
          check_ruby_llm_persistence(report)
          check_schema_presence(report)
          PersistenceRegistry.check(report, ::Smith.config.ruby_llm_model_registry)
        end

        def self.check_active_record(report)
          loaded = defined?(::ActiveRecord::Base)
          report.add(
            name: "persistence.active_record",
            status: loaded ? :pass : :fail,
            message: loaded ? "ActiveRecord available" : "ActiveRecord not available"
          )
        end

        def self.check_db_connection(report)
          unless defined?(::ActiveRecord::Base)
            report.add(name: "persistence.db_connection", status: :skip, message: "DB check skipped — no ActiveRecord")
            return
          end

          verify_active_connection(report)
        end

        def self.check_ruby_llm_persistence(report)
          detected = ruby_llm_persistence_detected?
          report.add(
            name: "persistence.ruby_llm_surface",
            status: detected ? :pass : :warn,
            message: detected ? "RubyLLM persistence surface detected" : "RubyLLM persistence surface not detected",
            detail: detected ? nil : "RubyLLM may be running in memory-only mode"
          )
        end

        def self.check_schema_presence(report)
          unless defined?(::ActiveRecord::Base)
            report.add(
              name: "persistence.schema_presence", status: :skip, message: "Schema check skipped — no ActiveRecord"
            )
            return
          end

          inspect_tables(report)
        end

        def self.check_model_registry_mode(report)
          PersistenceRegistry.check(report, ::Smith.config.ruby_llm_model_registry)
        end

        def self.verify_active_connection(report)
          active = ::ActiveRecord::Base.connection.active?
          report.add(
            name: "persistence.db_connection",
            status: active ? :pass : :fail,
            message: active ? "Database connection active" : "Database connection failed"
          )
        rescue StandardError => e
          report.add(name: "persistence.db_connection", status: :fail, message: "Database connection failed",
                     detail: e.message)
        end

        def self.ruby_llm_persistence_detected?
          return false unless defined?(::RubyLLM::Chat)

          ::RubyLLM::Chat.ancestors.any? { |a| a.name&.include?("ActiveRecord") }
        rescue StandardError
          false
        end

        def self.inspect_tables(report)
          tables = ::ActiveRecord::Base.connection.tables
          known = tables.select { |t| %w[chats messages tool_calls].include?(t) }

          if known.any?
            report.add(name: "persistence.schema_presence", status: :pass,
                       message: "RubyLLM tables found: #{known.join(", ")}")
          else
            report.add(name: "persistence.schema_presence", status: :warn,
                       message: "No RubyLLM persistence tables detected (heuristic)",
                       detail: "Expected tables like chats, messages, or tool_calls")
          end
        rescue StandardError => e
          report.add(name: "persistence.schema_presence", status: :warn,
                     message: "Schema check inconclusive", detail: e.message)
        end
      end
    end
  end
end
