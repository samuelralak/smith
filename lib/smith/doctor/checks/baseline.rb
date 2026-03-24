# frozen_string_literal: true

module Smith
  module Doctor
    module Checks
      module Baseline
        def self.run(report)
          check_smith_loads(report)
          check_ruby_version(report)
          check_ruby_llm_loads(report)
          check_concurrent_loads(report)
          check_configure(report)
          check_minimal_workflow(report)
        end

        def self.check_smith_loads(report)
          report.add(
            name: "baseline.smith_loads",
            status: defined?(::Smith) ? :pass : :fail,
            message: defined?(::Smith) ? "smith loads" : "smith failed to load",
            detail: defined?(::Smith) ? nil : "Ensure smith is in your Gemfile and bundle install has been run"
          )
        end

        def self.check_ruby_version(report)
          satisfied = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2.0")
          report.add(
            name: "baseline.ruby_version",
            status: satisfied ? :pass : :fail,
            message: satisfied ? "Ruby #{RUBY_VERSION}" : "Ruby #{RUBY_VERSION} is below minimum 3.2.0",
            detail: satisfied ? nil : "Smith requires Ruby >= 3.2.0"
          )
        end

        def self.check_ruby_llm_loads(report)
          loaded = defined?(::RubyLLM)
          report.add(
            name: "baseline.ruby_llm_loads",
            status: loaded ? :pass : :fail,
            message: loaded ? "ruby_llm loads" : "ruby_llm failed to load",
            detail: loaded ? nil : "Ensure ruby_llm is in your Gemfile"
          )
        end

        def self.check_concurrent_loads(report)
          loaded = defined?(::Concurrent)
          report.add(
            name: "baseline.concurrent_loads",
            status: loaded ? :pass : :fail,
            message: loaded ? "concurrent-ruby loads" : "concurrent-ruby failed to load",
            detail: loaded ? nil : "Ensure concurrent-ruby is in your Gemfile"
          )
        end

        def self.check_configure(report)
          callable = ::Smith.respond_to?(:configure) && ::Smith.respond_to?(:config)
          report.add(
            name: "baseline.configure",
            status: callable ? :pass : :fail,
            message: callable ? "Smith.configure callable" : "Smith.configure not available"
          )
        end

        def self.check_minimal_workflow(report)
          workflow_class = Class.new(::Smith::Workflow) do
            initial_state :idle
            state :done
            transition :check, from: :idle, to: :done
          end
          booted = workflow_class.new.state == :idle

          report.add(
            name: "baseline.minimal_workflow",
            status: booted ? :pass : :fail,
            message: booted ? "Minimal workflow boots" : "Minimal workflow failed to initialize"
          )
        rescue StandardError => e
          report.add(name: "baseline.minimal_workflow", status: :fail, message: "Minimal workflow failed",
                     detail: e.message)
        end
      end
    end
  end
end
