# frozen_string_literal: true

require "json"

module Smith
  module Doctor
    module Checks
      module Serialization
        def self.run(report)
          check_to_state(report)
          check_json_roundtrip(report)
          check_from_state(report)
          check_resume(report)
        end

        def self.check_to_state(report)
          state = build_probe_class.new.to_state
          valid = state.is_a?(Hash) && state.key?(:state) && state.key?(:class)
          report.add(
            name: "serialization.to_state",
            status: valid ? :pass : :fail,
            message: valid ? "to_state produces valid Hash" : "to_state output is malformed"
          )
        rescue StandardError => e
          report.add(name: "serialization.to_state", status: :fail, message: "to_state failed", detail: e.message)
        end

        def self.check_json_roundtrip(report)
          state = build_probe_class.new.to_state
          parsed = JSON.parse(JSON.generate(state))
          valid = parsed.is_a?(Hash) && parsed.key?("state")
          report.add(
            name: "serialization.json_roundtrip",
            status: valid ? :pass : :fail,
            message: valid ? "JSON round-trip preserves state" : "JSON round-trip corrupts state"
          )
        rescue StandardError => e
          report.add(name: "serialization.json_roundtrip", status: :fail, message: "JSON round-trip failed",
                     detail: e.message)
        end

        def self.check_from_state(report)
          klass = build_probe_class
          parsed = JSON.parse(JSON.generate(klass.new.to_state))
          restored = klass.from_state(parsed)
          valid = restored.state == :idle
          report.add(
            name: "serialization.from_state",
            status: valid ? :pass : :fail,
            message: valid ? "from_state restores workflow" : "from_state produced invalid state"
          )
        rescue StandardError => e
          report.add(name: "serialization.from_state", status: :fail, message: "from_state failed", detail: e.message)
        end

        def self.check_resume(report)
          result = build_probe_class.new.run!
          valid = result.state == :done
          report.add(
            name: "serialization.resume",
            status: valid ? :pass : :fail,
            message: valid ? "Workflow completes after restore" : "Workflow did not reach terminal state"
          )
        rescue StandardError => e
          report.add(name: "serialization.resume", status: :fail, message: "Resume failed", detail: e.message)
        end

        def self.build_probe_class
          Class.new(::Smith::Workflow) do
            initial_state :idle
            state :done
            transition :finish, from: :idle, to: :done
          end
        end
      end
    end
  end
end
