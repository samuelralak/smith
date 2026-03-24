# frozen_string_literal: true

module Smith
  module Doctor
    module Checks
      module Rails
        def self.run(report)
          unless defined?(::Rails)
            report.add(name: "rails.detected", status: :skip, message: "Rails not detected")
            return
          end

          check_application(report)
          check_smith_config(report)
        end

        def self.check_application(report)
          present = defined?(::Rails.application) && !::Rails.application.nil?
          report.add(
            name: "rails.application",
            status: present ? :pass : :fail,
            message: present ? "Rails application present" : "Rails application not found",
            detail: present ? nil : "Rails is loaded but no application is defined"
          )
        end

        def self.check_smith_config(report)
          accessible = ::Smith.respond_to?(:config) && !::Smith.config.nil?
          report.add(
            name: "rails.smith_config",
            status: accessible ? :pass : :warn,
            message: accessible ? "Smith config accessible from Rails" : "Smith config not accessible",
            detail: accessible ? nil : "Ensure config/initializers/smith.rb exists"
          )
        end
      end
    end
  end
end
