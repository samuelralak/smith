# frozen_string_literal: true

require "dry-initializer"

require_relative "fanout_contract"
require_relative "optimization_contract"
require_relative "orchestration_contract"

module Smith
  class Workflow
    class Graph
      class TransitionSnapshot
        extend Dry::Initializer

        KINDS = [
          %i[deterministic deterministic?],
          %i[router routed?],
          %i[nested_workflow nested?],
          %i[optimizer optimized?],
          %i[orchestrator orchestrated?],
          %i[fanout fanout?],
          %i[parallel parallel?]
        ].freeze

        option :name
        option :from
        option :to
        option :kind
        option :success_transition, default: proc {}
        option :failure_transition, default: proc {}
        option :routes, default: proc {}
        option :fallback, default: proc {}
        option :deterministic_routes, default: proc {}
        option :fanout_branches, default: proc {}
        option :fanout, default: proc {}
        option :optimization, default: proc {}
        option :orchestration, default: proc {}
        option :retry_policy, default: proc {}

        def self.from_transition(transition, workflow_class: nil)
          new(**attributes_for(transition, workflow_class: workflow_class))
        end

        def self.attributes_for(transition, workflow_class:)
          {
            name: transition.name,
            from: transition.from,
            to: transition.to,
            kind: kind_for(transition)
          }.merge(routing_attributes(transition), contract_attributes(transition, workflow_class: workflow_class))
        end

        def self.routing_attributes(transition)
          {
            success_transition: transition.success_transition,
            failure_transition: transition.failure_transition,
            routes: transition.router_config&.fetch(:routes, nil),
            fallback: transition.router_config&.fetch(:fallback, nil),
            deterministic_routes: transition.deterministic_routes,
            fanout_branches: transition.fanout_config&.fetch(:branches, nil)
          }
        end

        def self.contract_attributes(transition, workflow_class:)
          {
            fanout: fanout_for(transition, workflow_class: workflow_class),
            optimization: optimization_for(transition, workflow_class: workflow_class),
            orchestration: orchestration_for(transition, workflow_class: workflow_class),
            retry_policy: retry_policy_for(transition)
          }
        end

        def self.fanout_for(transition, workflow_class:)
          FanoutContract.from_transition(transition, workflow_class: workflow_class)
        end

        def self.optimization_for(transition, workflow_class:)
          OptimizationContract.from_transition(transition, workflow_class: workflow_class)
        end

        def self.orchestration_for(transition, workflow_class:)
          OrchestrationContract.from_transition(transition, workflow_class: workflow_class)
        end

        def self.retry_policy_for(transition)
          config = transition.retry_config
          return unless config

          {
            attempts: config.fetch(:attempts),
            error_classes: config.fetch(:error_classes).map(&:name),
            backoff: config.fetch(:backoff),
            max_delay: config[:max_delay],
            jitter: config.fetch(:jitter)
          }.compact
        end

        def self.kind_for(transition)
          kind = KINDS.find { |_name, predicate| transition.public_send(predicate) }
          return kind.first if kind
          return :agent if transition.agent_name

          :noop
        end

        def to_h
          {
            name: name,
            from: from,
            to: to,
            kind: kind,
            success_transition: success_transition,
            failure_transition: failure_transition,
            routes: routes,
            fallback: fallback,
            deterministic_routes: deterministic_routes,
            fanout_branches: fanout_branches,
            fanout: fanout,
            optimization: optimization,
            orchestration: orchestration,
            retry_policy: retry_policy
          }.compact
        end
      end
    end
  end
end
