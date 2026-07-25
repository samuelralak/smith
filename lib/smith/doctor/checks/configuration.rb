# frozen_string_literal: true

module Smith
  module Doctor
    module Checks
      module Configuration
        def self.run(report)
          check_logger(report)
          check_artifact_store(report)
          check_trace_adapter(report)
          check_pricing(report)
        end

        def self.check_logger(report)
          configured = !::Smith.config.logger.nil?
          report.add(
            name: "config.logger",
            status: configured ? :pass : :warn,
            message: configured ? "Logger configured" : "No logger configured",
            detail: configured ? nil : "Set config.logger for Smith runtime logging"
          )
        end

        def self.check_artifact_store(report)
          configured = !::Smith.config.artifact_store.nil?
          report.add(
            name: "config.artifact_store",
            status: configured ? :pass : :warn,
            message: configured ? "Artifact store configured" : "No artifact store configured",
            detail: configured ? nil : "Large outputs will use in-memory default"
          )
        end

        def self.check_trace_adapter(report)
          configured = !::Smith.config.trace_adapter.nil?
          report.add(
            name: "config.trace_adapter",
            status: configured ? :pass : :warn,
            message: configured ? "Trace adapter configured" : "No trace adapter configured",
            detail: configured ? nil : "Traces will be discarded"
          )
        end

        def self.check_pricing(report)
          configured = ::Smith.config.pricing.is_a?(Hash) && !::Smith.config.pricing.empty?
          unless configured
            report.add(
              name: "config.pricing",
              status: :warn,
              message: "No pricing configured",
              detail: "RunResult.total_cost will be 0.0"
            )
            return
          end

          ::Smith::Pricing.validate_catalog!
          report.add(name: "config.pricing", status: :pass, message: "Pricing configured")
        rescue ::Smith::PricingConfigurationError => e
          report.add(
            name: "config.pricing",
            status: :fail,
            message: "Pricing catalog invalid",
            detail: e.message
          )
        end
      end
    end
  end
end
