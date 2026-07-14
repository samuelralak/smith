# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      class TransitionOptimizationConfiguration
        extend Dry::Initializer

        param :config

        def to_h
          identity
            .merge(evaluation)
            .merge(exit_modes)
            .freeze
        end

        private

        def identity
          {
            generator: own(config.fetch(:generator)),
            evaluator: own(config.fetch(:evaluator)),
            max_rounds: config.fetch(:max_rounds)
          }
        end

        def evaluation
          {
            evaluator_schema_label: label(config.fetch(:evaluator_schema)),
            evaluator_context: callable_marker(config[:evaluator_context]),
            improvement_threshold: config[:improvement_threshold],
            before_eval: callable_marker(config[:before_eval])
          }
        end

        def exit_modes
          {
            on_exhaustion: callable_marker(config.fetch(:on_exhaustion)),
            on_converged: callable_marker(config.fetch(:on_converged)),
            on_threshold: callable_marker(config.fetch(:on_threshold))
          }
        end

        def own(value)
          value.is_a?(String) ? value.dup.freeze : value
        end

        def label(value)
          result = value.respond_to?(:name) && value.name && !value.name.empty? ? value.name : value.inspect
          result.dup.freeze
        end

        def callable_marker(value)
          value.respond_to?(:call) ? :callable : own(value)
        end
      end
    end
  end
end
