# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # A streamed step needs its sink in Smith.config.stream_sinks (the
      # step fails without it). An agent with tools and an OpenAI model may
      # be sent through the Responses API (`openai_api_mode` :auto), which
      # does not stream: its sink gets each reply as one delta.
      class StreamDiagnostic
        extend Dry::Initializer

        param :graph

        def to_a
          graph.reachable_transitions.filter_map do |transition|
            next unless transition.stream
            next missing_sink(transition) unless Smith.config.stream_sinks.key?(transition.stream)

            whole_replies(transition) if responses_route?(transition.agent_name)
          end
        end

        private

        def responses_route?(agent)
          agent_class = Agent::Registry.binding_for(agent)&.fetch(:agent_class)
          return false unless Smith.config.openai_api_mode == :auto && agent_class.respond_to?(:tools)
          return false if agent_class.tools.respond_to?(:empty?) && agent_class.tools.empty?

          static_models(agent_class).any? { |reference| openai?(reference) }
        end

        def static_models(agent_class)
          primary = agent_class.chat_kwargs[:model] &&
                    Agent::ModelReference.new(model_id: agent_class.chat_kwargs[:model],
                                              provider: agent_class.chat_kwargs[:provider])
          fallbacks = agent_class.fallback_models_block ? [] : Array(agent_class.fallback_models)
          [primary, *fallbacks.map { Agent::ModelReference.coerce(_1) }].compact
        end

        def openai?(reference)
          provider = reference.provider || Smith::Models.find_or_infer(reference.model_id)&.provider
          provider.to_s == "openai"
        rescue StandardError
          false
        end

        def missing_sink(transition)
          Diagnostic.new(
            severity: :error, code: :stream_sink_missing, transition: transition.name, target: transition.stream,
            message: "Transition #{Reference.format(transition.name)} streams to #{transition.stream.inspect}, " \
                     "which Smith.config.stream_sinks does not name.",
            suggestion: "Register the sink: Smith.config.stream_sinks = { #{transition.stream.inspect} => sink }."
          )
        end

        def whole_replies(transition)
          Diagnostic.new(
            severity: :warning, code: :stream_whole_replies, transition: transition.name,
            target: transition.agent_name,
            message: "Transition #{Reference.format(transition.name)} streams agent " \
                     "#{Reference.format(transition.agent_name)}, whose tools and OpenAI model may send it " \
                     "through the Responses API, which does not stream: its sink would get each reply as one delta.",
            suggestion: "Accept whole replies there, or set Smith.config.openai_api_mode = :off."
          )
        end
      end
    end
  end
end
