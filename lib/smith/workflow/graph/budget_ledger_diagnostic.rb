# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # A workflow with a `budget_ledger` holds each provider request on it,
      # priced from the pricing catalog under the id RubyLLM resolves the
      # model to (as holds and Smith's own usage are): an agent whose model
      # (or fallback model) has no price there gives the ledger holds and
      # amounts without a cost (nil), a warning. The agents are those of each
      # step (a fan-out's branches, an optimizer's generator and evaluator,
      # an orchestrator and its worker) and of a nested workflow without a
      # ledger of its own, which charges this one. A model given by a block
      # is known only per run, and is not checked. A child run (`call`, `map`,
      # `spawn`) is a run of its own, held on its own class's ledger: one
      # whose class names none sends its requests unheld, also a warning.
      class BudgetLedgerDiagnostic
        extend Dry::Initializer

        param :graph

        def self.declared?(workflow_class)
          workflow_class.respond_to?(:budget_ledger) && !workflow_class.budget_ledger.nil?
        end

        def to_a
          return [] unless self.class.declared?(graph.workflow_class)

          graph.reachable_transitions.flat_map do |transition|
            [*agents(transition, Set[graph.workflow_class]).uniq.filter_map { unpriced(transition, _1) },
             *unbudgeted_child(transition)]
          end
        end

        private

        def agents(transition, seen)
          [*step_agents(transition), *(nested_agents(transition.workflow_class, seen) if transition.nested?)].compact
        end

        def step_agents(transition)
          return transition.fanout_config.fetch(:branches).values if transition.fanout?
          return transition.optimization_config.values_at(:generator, :evaluator) if transition.optimized?
          return transition.orchestrator_config.values_at(:orchestrator, :worker) if transition.orchestrated?

          [transition.agent_name]
        end

        def unbudgeted_child(transition)
          child = transition.children_config&.fetch(:workflow)
          return if child.nil? || self.class.declared?(child)

          name = child.name || child.inspect
          Diagnostic.new(
            severity: :warning, code: :child_run_unbudgeted, transition: transition.name, target: name,
            message: "Transition #{Reference.format(transition.name)} starts runs of #{name}, which declares no " \
                     "budget_ledger: a child run is a run of its own, so its provider requests are held on no " \
                     "ledger and go unapproved and uncounted.",
            suggestion: "Declare budget_ledger on #{name}, scoped by a key the parent passes in each child's " \
                        "input (budget_ledger(:account_id) { |scope| ... })."
          )
        end

        # A nested workflow without its own ledger charges this one.
        def nested_agents(workflow_class, seen)
          return [] if seen.include?(workflow_class) || self.class.declared?(workflow_class) ||
                       !workflow_class.respond_to?(:graph)

          seen << workflow_class
          workflow_class.graph.reachable_transitions.flat_map { agents(_1, seen) }
        end

        def unpriced(transition, agent)
          agent_class = Agent::Registry.binding_for(agent)&.fetch(:agent_class)
          return unless agent_class.respond_to?(:chat_kwargs)

          model = models(agent_class).find { |reference| !priced?(reference) }
          return unless model

          Diagnostic.new(
            severity: :warning, code: :budget_ledger_unpriced, transition: transition.name, target: agent,
            message: "Transition #{Reference.format(transition.name)} holds agent #{Reference.format(agent)}'s " \
                     "requests on the workflow's budget_ledger, and its model #{model.model_id} has no price " \
                     "in Smith.config.pricing, so their amounts carry no cost.",
            suggestion: "Price the model in Smith.config.pricing, or have the ledger count tokens."
          )
        end

        # The models the agent's calls are priced under: its own and its
        # fallbacks', as RubyLLM resolves them.
        def models(agent_class)
          kwargs = agent_class.chat_kwargs
          primary = kwargs[:model] && resolved(kwargs[:model], provider_of(agent_class), kwargs[:assume_model_exists])
          [primary, *Array(agent_class.fallback_models).map { reference(Agent::ModelReference.coerce(_1)) }].compact
        rescue StandardError
          []
        end

        def reference(coerced) = resolved(coerced.model_id, coerced.provider&.to_s, false)

        def resolved(model_id, provider, assume)
          info = RubyLLM::Models.resolve(model_id, provider:, assume_exists: assume || false).first
          Agent::ModelReference.new(model_id: info.id, provider: provider || info.provider.to_s)
        rescue StandardError
          Agent::ModelReference.new(model_id:, provider:)
        end

        def provider_of(agent_class)
          provider = agent_class.chat_kwargs[:provider]
          return provider.to_s if provider

          Smith::Models.find_or_infer(agent_class.chat_kwargs[:model])&.provider&.to_s
        rescue StandardError
          nil
        end

        def priced?(reference)
          !Pricing.compute_cost(model: reference.model_id, provider: reference.provider&.to_s, input_tokens: 0,
                                output_tokens: 0).nil?
        end
      end
    end
  end
end
