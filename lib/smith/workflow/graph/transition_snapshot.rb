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
        option :parallel_count, default: proc {}
        option :success_transition, default: proc {}
        option :failure_transition, default: proc {}
        option :timeout_transition, default: proc {}
        option :routes, default: proc {}
        option :fallback, default: proc {}
        option :deterministic_routes, default: proc {}
        option :deterministic_fallthrough, default: proc {}
        option :fanout_branches, default: proc {}
        option :fanout, default: proc {}
        option :optimization, default: proc {}
        option :orchestration, default: proc {}
        option :retry_policy, default: proc {}
        option :wait, default: proc {}
        option :input, default: proc {}
        option :output_to, default: proc {}
        option :children, default: proc {}

        def self.from_transition(transition, workflow_class: nil)
          new(**attributes_for(transition, workflow_class: workflow_class))
        end

        def self.attributes_for(transition, workflow_class:)
          {
            name: transition.name,
            from: transition.from,
            to: transition.to,
            kind: kind_for(transition),
            parallel_count: transition.parallel_count
          }.merge(routing_attributes(transition), contract_attributes(transition, workflow_class: workflow_class))
        end

        def self.routing_attributes(transition)
          {
            success_transition: transition.success_transition,
            failure_transition: transition.failure_transition,
            timeout_transition: transition.timeout_transition,
            routes: transition.router_config&.fetch(:routes, nil),
            fallback: transition.router_config&.fetch(:fallback, nil),
            deterministic_routes: transition.deterministic_routes,
            deterministic_fallthrough: transition.deterministic_routes && transition.deterministic_fallthrough == true,
            fanout_branches: transition.fanout_config&.fetch(:branches, nil)
          }
        end

        def self.contract_attributes(transition, workflow_class:)
          {
            fanout: FanoutContract.from_transition(transition, workflow_class:),
            optimization: OptimizationContract.from_transition(transition, workflow_class:),
            orchestration: OrchestrationContract.from_transition(transition, workflow_class:),
            retry_policy: retry_policy_for(transition),
            wait: transition.await_config,
            input: (:callable if transition.step_input),
            output_to: transition.output_to,
            children: children_for(transition)
          }
        end

        def self.retry_policy_for(transition)
          config = transition.retry_config
          return unless config

          new_key_classes = config.fetch(:new_idempotency_key_on, [])
          {
            attempts: config.fetch(:attempts),
            error_classes: config.fetch(:error_classes).map(&:name),
            backoff: config.fetch(:backoff),
            max_delay: config[:max_delay],
            jitter: config.fetch(:jitter),
            new_idempotency_key_on: (new_key_classes.map(&:name) if new_key_classes.any?)
          }.compact
        end

        # A map, call or spawn: its child workflow (by name), bound, collect
        # and failure modes, and its items (a context key, or :callable).
        def self.children_for(transition)
          config = transition.children_config
          return unless config

          workflow = config[:workflow]
          config.merge(workflow: workflow.name || workflow.inspect)
        end

        def self.kind_for(transition)
          return transition.children_config.fetch(:kind) if transition.child_runs?
          return transition.await_config.fetch(:kind) if transition.awaits?

          kind = KINDS.find { |_name, predicate| transition.public_send(predicate) }
          return kind.first if kind
          return :agent if transition.agent_name

          :noop
        end

        def to_h
          self.class.dry_initializer.attributes(self).compact
        end
      end
    end
  end
end
