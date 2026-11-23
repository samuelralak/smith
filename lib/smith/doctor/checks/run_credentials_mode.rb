# frozen_string_literal: true

module Smith
  module Doctor
    module Checks
      # The fail-closed mode for run credentials (Smith.config.
      # require_run_credentials), checked only when it is on: RubyLLM's global
      # logger must not write response bodies, which may echo part of a run's
      # key; no provider key should be left in RubyLLM's global configuration,
      # nor cloud credentials a cloud SDK finds on its own, which a host's own
      # RubyLLM calls would send; and every workflow class that asks an agent
      # must declare provider_credentials, as the mode refuses its provider
      # requests (one that asks none, an abstract base or a compute-only
      # workflow, needs none; one only a credentialed class nests sends on
      # its parent's). Only the classes loaded when it runs are seen.
      module RunCredentialsMode
        def self.run(report)
          return unless ::Smith.config.require_run_credentials

          require_relative "../../provider_options"
          require_relative "../../run_credentials_readiness"
          check_logging(report)
          check_global_keys(report)
          check_ambient(report)
          check_classes(report)
        end

        def self.check_logging(report)
          why = ::Smith::ProviderOptions.body_logging
          report.add(
            name: "run_credentials.logging",
            status: why ? :fail : :pass,
            message: why ? "RubyLLM logs response bodies: #{why}" : "RubyLLM logs no bodies",
            detail: why ? "Run RubyLLM's logger at INFO or above, with log_stream_debug off" : nil
          )
        end

        def self.check_global_keys(report)
          present = ::Smith::ProviderOptions.global_secrets?
          report.add(
            name: "run_credentials.global_keys",
            status: present ? :warn : :pass,
            message: present ? "A provider key is set in RubyLLM's global configuration" : "No global provider keys",
            detail: present ? "Runs use their own keys; leave none in RubyLLM.config" : nil
          )
        end

        def self.check_ambient(report)
          found = ::Smith::ProviderOptions.ambient_credentials
          report.add(
            name: "run_credentials.ambient_credentials",
            status: found.empty? ? :pass : :warn,
            message: found.empty? ? "No cloud credentials found" : "Cloud credentials found: #{found.join(", ")}",
            detail: found.empty? ? nil : "No run sends them; a host's own calls could. Keep them out of the worker"
          )
        end

        def self.check_classes(report)
          undeclared = undeclared_classes
          report.add(
            name: "run_credentials.workflow_classes",
            status: undeclared.empty? ? :pass : :fail,
            message: if undeclared.empty?
                       "Every loaded workflow class declares provider_credentials"
                     else
                       "#{undeclared.length} loaded workflow classes declare no provider_credentials"
                     end,
            detail: undeclared.empty? ? nil : "Their provider requests are refused: #{undeclared.join(", ")}"
          )
        end

        # Named workflow classes loaded now that ask an agent and declare
        # none, but those a credentialed class nests, which send on its
        # credentials.
        def self.undeclared_classes
          classes = descendants(::Smith::Workflow).select(&:name).uniq
          declared = classes.select(&:provider_credentials)
          nested = declared.each_with_object(Set.new) { |klass, seen| nested_of(klass, seen) }
          (classes - declared - nested.to_a).select { asks_agents?(_1) }.map(&:name).sort
        end

        def self.asks_agents?(klass)
          ::Smith::RunCredentialsReadiness.asks_agents?(klass)
        rescue StandardError
          false
        end

        def self.descendants(klass) = klass.subclasses.flat_map { [_1, *descendants(_1)] }

        # Adds to `seen` each class `klass` nests, through those without
        # their own declaration.
        def self.nested_of(klass, seen)
          klass.graph.reachable_transitions.each do |transition|
            nested = transition.workflow_class
            next if nested.nil? || nested.provider_credentials || seen.include?(nested)

            seen << nested
            nested_of(nested, seen)
          end
        rescue StandardError
          seen
        end
      end
    end
  end
end
