# frozen_string_literal: true

require "dry-initializer"

require_relative "transition_optimization_configuration"

module Smith
  class Workflow
    class Graph
      class TransitionContractConfigurations
        extend Dry::Initializer

        param :transition
        option :identifiers

        def to_h
          {
            router_config: router_config,
            optimization_config: optimization_config,
            orchestrator_config: orchestrator_config,
            fanout_config: fanout_config,
            retry_config: retry_config
          }
        end

        private

        def router_config
          config = transition.router_config
          return unless config

          {
            routes: project_routes(config.fetch(:routes)),
            confidence_threshold: config.fetch(:confidence_threshold),
            fallback: identifiers.call(config.fetch(:fallback))
          }.freeze
        end

        def optimization_config
          config = transition.optimization_config
          TransitionOptimizationConfiguration.new(config).to_h if config
        end

        def orchestrator_config
          config = transition.orchestrator_config
          return unless config

          {
            orchestrator: own(config.fetch(:orchestrator)),
            worker: own(config.fetch(:worker)),
            max_workers: config.fetch(:max_workers),
            max_delegation_rounds: config.fetch(:max_delegation_rounds),
            task_schema_label: label(config.fetch(:task_schema)),
            worker_output_schema_label: label(config.fetch(:worker_output_schema)),
            final_output_schema_label: label(config.fetch(:final_output_schema))
          }.freeze
        end

        def fanout_config
          branches = transition.fanout_config&.fetch(:branches, nil)
          { branches: own_hash(branches) }.freeze if branches
        end

        def retry_config
          config = transition.retry_config
          return unless config

          {
            error_classes: config.fetch(:error_classes).dup.freeze,
            attempts: config.fetch(:attempts),
            backoff: config.fetch(:backoff),
            max_delay: config[:max_delay],
            jitter: config.fetch(:jitter)
          }.freeze
        end

        def own_hash(hash)
          hash.each_with_object({}) do |(key, value), copy|
            copy[own(key)] = own(value)
          end.freeze
        end

        def project_routes(routes)
          routes.each_with_object({}) do |(key, transition_name), copy|
            copy[own(key)] = identifiers.call(transition_name)
          end.freeze
        end

        def own(value)
          value.is_a?(String) ? value.dup.freeze : value
        end

        def label(value)
          result = value.respond_to?(:name) && value.name && !value.name.empty? ? value.name : value.inspect
          result.dup.freeze
        end
      end
    end
  end
end
