# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # A step that may send its requests as a batch (`mode:`) needs
      # Smith.config.batch_queue, and agents whose calls can go as one: a
      # model whose provider has a batch interface in Smith (Anthropic's) and
      # no tools (a batch request is one turn). Errors for `mode: :batch`;
      # warnings for a mode callable, which may choose :sync.
      class BatchDiagnostic
        extend Dry::Initializer

        param :graph

        def to_a
          graph.reachable_transitions.select(&:batches?).flat_map do |transition|
            severity = transition.batch_mode == :batch ? :error : :warning
            [*queue_missing(transition), *agents(transition).filter_map { unavailable(transition, _1, severity) }]
          end
        end

        private

        def agents(transition)
          return transition.fanout_config.fetch(:branches).values if transition.fanout?

          [transition.agent_name]
        end

        def queue_missing(transition)
          return [] if Smith.config.batch_queue

          [Diagnostic.new(
            severity: :error, code: :batch_queue_missing, transition: transition.name,
            message: "Transition #{Reference.format(transition.name)} may send its requests as a batch, which goes " \
                     "through Smith.config.batch_queue, and none is configured.",
            suggestion: "Set Smith.config.batch_queue to the host's queue (enqueue(custom_id:, await_token:, " \
                        "request:, execution_key:))."
          )]
        end

        def unavailable(transition, agent, severity)
          agent_class = Agent::Registry.binding_for(agent)&.fetch(:agent_class)
          return unless agent_class.respond_to?(:chat_kwargs)

          reason = unavailable_reason(agent_class)
          return unless reason

          Diagnostic.new(
            severity:, code: :batch_unavailable, transition: transition.name, target: agent,
            message: "Transition #{Reference.format(transition.name)} may batch agent #{Reference.format(agent)}, " \
                     "#{reason}.",
            suggestion: "Give the agent an Anthropic model and no tools, or keep the step synchronous."
          )
        end

        def unavailable_reason(agent_class)
          tools = agent_class.respond_to?(:tools) ? agent_class.tools : []
          return "which has tools (a batch request is one turn)" unless tools.respond_to?(:empty?) && tools.empty?

          provider = provider_of(agent_class)
          "whose model's provider (#{provider || "unknown"}) has no batch interface in Smith" unless
            provider == "anthropic"
        end

        def provider_of(agent_class)
          model, provider = agent_class.chat_kwargs.values_at(:model, :provider)
          return provider.to_s if provider
          return unless model

          Smith::Models.find_or_infer(model)&.provider&.to_s
        rescue StandardError
          nil
        end
      end
    end
  end
end
