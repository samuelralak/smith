# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # A streamed step needs its sink in Smith.config.stream_sinks (the
      # step fails without it). An agent whose calls go to OpenAI's Responses
      # API (asked for in its params, or chosen by Smith's tool routing under
      # `openai_api_mode` :auto, as at runtime) is not streamed: its sink
      # gets each reply as one delta.
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
          return false unless agent_class.respond_to?(:chat_kwargs)

          profiles = static_models(agent_class).filter_map { profile(_1) }.select { _1.provider == :openai }
          return false if profiles.empty?
          return true if params(agent_class)[:openai_api_mode].to_s == "responses"

          profiles.any? { |profile| routed?(profile, agent_class) }
        end

        # Tools given by a block are known only per run: they may route.
        def routed?(profile, agent_class)
          tools = agent_class.respond_to?(:tools) ? agent_class.tools : []
          return Smith.config.openai_api_mode == :auto unless tools.is_a?(Array)

          Smith::Models::ToolRouting.responses?(profile:, tools:, thinking: thinking?(agent_class))
        end

        def static_models(agent_class)
          primary = agent_class.chat_kwargs[:model] &&
                    Agent::ModelReference.new(model_id: agent_class.chat_kwargs[:model],
                                              provider: agent_class.chat_kwargs[:provider])
          fallbacks = agent_class.fallback_models_block ? [] : Array(agent_class.fallback_models)
          [primary, *fallbacks.map { Agent::ModelReference.coerce(_1) }].compact
        end

        def profile(reference)
          Smith::Models.find_or_infer(reference.model_id, provider: reference.provider&.to_sym)
        rescue StandardError
          nil
        end

        def params(agent_class)
          params = agent_class.params if agent_class.respond_to?(:params)
          params.is_a?(Hash) ? params.transform_keys(&:to_sym) : {}
        end

        def thinking?(agent_class)
          configured = agent_class.thinking if agent_class.respond_to?(:thinking)
          !configured.nil? || params(agent_class).keys.intersect?(%i[thinking reasoning reasoning_effort])
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
                     "#{Reference.format(transition.agent_name)}, whose calls go to OpenAI's Responses API, which " \
                     "does not stream: its sink gets each reply as one delta.",
            suggestion: "Accept whole replies there, or keep the agent on Chat Completions " \
                        "(Smith.config.openai_api_mode = :off, and no openai_api_mode param)."
          )
        end
      end
    end
  end
end
