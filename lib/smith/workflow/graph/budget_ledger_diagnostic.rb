# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # A workflow with a `budget_ledger` holds each provider request on it,
      # priced from the pricing catalog: an agent whose model (or fallback
      # model) has no price there gives the ledger holds and amounts without
      # a cost (nil), a warning. A model given by a block is known only per
      # run, and is not checked.
      class BudgetLedgerDiagnostic
        extend Dry::Initializer

        param :graph

        def to_a
          return [] unless graph.workflow_class.respond_to?(:budget_ledger) && graph.workflow_class.budget_ledger

          graph.reachable_transitions.flat_map do |transition|
            agents(transition).filter_map { unpriced(transition, _1) }
          end
        end

        private

        def agents(transition)
          return transition.fanout_config.fetch(:branches).values if transition.fanout?

          [transition.agent_name].compact
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

        def models(agent_class)
          primary = agent_class.chat_kwargs[:model]
          references = primary ? [Agent::ModelReference.new(model_id: primary, provider: provider_of(agent_class))] : []
          references + Array(agent_class.fallback_models).map { Agent::ModelReference.coerce(_1) }
        rescue StandardError
          []
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
