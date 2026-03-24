# frozen_string_literal: true

require_relative "doctor/check"
require_relative "doctor/report"
require_relative "doctor/printer"
require_relative "doctor/installer"
require_relative "doctor/checks/baseline"
require_relative "doctor/checks/configuration"
require_relative "doctor/checks/rails"
require_relative "doctor/checks/persistence"
require_relative "doctor/checks/persistence_registry"
require_relative "doctor/checks/serialization"
require_relative "doctor/checks/durability"
require_relative "doctor/checks/live"

module Smith
  module Doctor
    def self.run(profile: :auto, live: false, durability: false, io: $stdout)
      report = Report.new

      Checks::Baseline.run(report)
      Checks::Configuration.run(report)
      Checks::Rails.run(report) if detect_rails?
      Checks::Persistence.run(report) if persistence_profile?(profile)
      if durability || durability_profile?(profile)
        Checks::Serialization.run(report)
        Checks::Durability.run(report)
      end
      Checks::Live.run(report) if live

      Printer.new(report, io:).print
      report
    end

    def self.detect_rails?
      defined?(::Rails::Railtie)
    end

    def self.persistence_profile?(profile)
      profile == :rails_persistence
    end

    def self.durability_profile?(profile)
      profile == :durable
    end
  end
end
