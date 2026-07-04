# frozen_string_literal: true

require_relative "fanout_contract"

module Smith
  class Workflow
    class Graph
      class TransitionSnapshot
        KINDS = [
          %i[deterministic deterministic?],
          %i[router routed?],
          %i[nested_workflow nested?],
          %i[optimizer optimized?],
          %i[orchestrator orchestrated?],
          %i[fanout fanout?],
          %i[parallel parallel?]
        ].freeze

        attr_reader :name, :from, :to, :kind, :success_transition, :failure_transition, :routes, :fallback,
                    :deterministic_routes, :fanout_branches, :fanout, :retry_policy

        def self.from_transition(transition, workflow_class: nil)
          new(
            name: transition.name,
            from: transition.from,
            to: transition.to,
            kind: kind_for(transition),
            success_transition: transition.success_transition,
            failure_transition: transition.failure_transition,
            routes: transition.router_config&.fetch(:routes, nil),
            fallback: transition.router_config&.fetch(:fallback, nil),
            deterministic_routes: transition.deterministic_routes,
            fanout_branches: transition.fanout_config&.fetch(:branches, nil),
            fanout: fanout_for(transition, workflow_class: workflow_class),
            retry_policy: retry_policy_for(transition)
          )
        end

        def self.fanout_for(transition, workflow_class:)
          FanoutContract.from_transition(transition, workflow_class: workflow_class)
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

        def initialize(**attributes)
          @name = attributes.fetch(:name)
          @from = attributes.fetch(:from)
          @to = attributes.fetch(:to)
          @kind = attributes.fetch(:kind)
          @success_transition = attributes[:success_transition]
          @failure_transition = attributes[:failure_transition]
          @routes = attributes[:routes]
          @fallback = attributes[:fallback]
          @deterministic_routes = attributes[:deterministic_routes]
          @fanout_branches = attributes[:fanout_branches]
          @fanout = attributes[:fanout]
          @retry_policy = attributes[:retry_policy]
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
            retry_policy: retry_policy
          }.compact
        end
      end
    end
  end
end
