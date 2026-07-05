# frozen_string_literal: true

require "dry-initializer"

require_relative "contract_helpers"

module Smith
  class Workflow
    class Graph
      class OptimizationContract
        extend Dry::Initializer
        include ContractHelpers

        param :transition
        option :workflow_class, default: proc {}

        def self.from_transition(transition, workflow_class: nil)
          new(transition, workflow_class: workflow_class).to_h if transition.optimization_config
        end

        def to_h
          deep_freeze(
            transition_contract.merge(
              exit_modes: exit_modes,
              output_contract: output_contract,
              resume_contract: resume_contract
            ).compact
          )
        end

        private

        def config
          transition.optimization_config
        end

        def transition_contract
          {
            generator: immutable_value(config.fetch(:generator)),
            evaluator: immutable_value(config.fetch(:evaluator)),
            max_rounds: config.fetch(:max_rounds)
          }.merge(evaluation_contract)
        end

        def evaluation_contract
          {
            evaluator_schema: label_for(config.fetch(:evaluator_schema)),
            evaluator_context: config[:evaluator_context],
            improvement_threshold: config[:improvement_threshold],
            before_eval: callable_label(config[:before_eval])
          }
        end

        def exit_modes
          {
            exhaustion: exit_mode_label(config.fetch(:on_exhaustion)),
            converged: exit_mode_label(config.fetch(:on_converged)),
            threshold: exit_mode_label(config.fetch(:on_threshold))
          }
        end

        def output_contract
          {
            success: :accepted_or_configured_exit_candidate,
            failure: :workflow_error_on_malformed_or_unaccepted_evaluation,
            evaluator_output: {
              required: { accept: :boolean },
              rejection_requires: %i[feedback],
              threshold_requires: %i[score],
              optional: %i[score converged]
            }
          }
        end

        def resume_contract
          {
            granularity: :transition,
            round_checkpointing: false,
            idempotency_mode: idempotency_mode,
            in_flight_resume: in_flight_resume
          }
        end

        def exit_mode_label(value)
          return value if value.is_a?(Symbol)

          callable_label(value)
        end

        def callable_label(value)
          value.respond_to?(:call) ? :callable : nil
        end
      end
    end
  end
end
