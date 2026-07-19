# frozen_string_literal: true

require "dry-initializer"

require_relative "transition_contract_configurations"

module Smith
  class Workflow
    class Graph
      class TransitionContractAttributes
        extend Dry::Initializer

        param :transition
        option :identifiers

        def to_h
          identity_attributes
            .merge(routing_attributes)
            .merge(kind_attributes)
            .merge(TransitionContractConfigurations.new(transition, identifiers:).to_h)
        end

        private

        def identity_attributes
          {
            name: identifiers.call(transition.name),
            from: identifiers.call(transition.from),
            to: identifiers.call(transition.to),
            agent_name: own(transition.agent_name),
            workflow_class: transition.workflow_class
          }
        end

        def routing_attributes
          {
            success_transition: project(transition.success_transition),
            failure_transition: project(transition.failure_transition),
            deterministic_routes: project_array(transition.deterministic_routes)
          }
        end

        def kind_attributes
          {
            deterministic_kind: transition.deterministic_kind,
            deterministic: transition.deterministic?,
            parallel: transition.parallel?,
            parallel_count: static_parallel_count
          }
        end

        def static_parallel_count
          return unless transition.parallel?

          count = transition.agent_opts[:count]
          count.respond_to?(:call) ? nil : (count || 1)
        end

        def project_array(array)
          array&.map { identifiers.call(_1) }&.freeze
        end

        def project(value)
          identifiers.call(value) unless value.nil?
        end

        def own(value)
          value.is_a?(String) ? value.dup.freeze : value
        end
      end
    end
  end
end
