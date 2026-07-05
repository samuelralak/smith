# frozen_string_literal: true

require "dry-initializer"

require_relative "contract_helpers"

module Smith
  class Workflow
    class Graph
      class OrchestrationContract
        extend Dry::Initializer
        include ContractHelpers

        param :transition
        option :workflow_class, default: proc {}

        def self.from_transition(transition, workflow_class: nil)
          new(transition, workflow_class: workflow_class).to_h if transition.orchestrator_config
        end

        def to_h
          deep_freeze(
            transition_contract.merge(
              decision_contract: decision_contract,
              output_contract: output_contract,
              resume_contract: resume_contract
            )
          )
        end

        private

        def config
          transition.orchestrator_config
        end

        def transition_contract
          {
            orchestrator: immutable_value(config.fetch(:orchestrator)),
            worker: immutable_value(config.fetch(:worker)),
            max_workers: config.fetch(:max_workers),
            max_delegation_rounds: config.fetch(:max_delegation_rounds),
            worker_dispatch: :serial
          }.merge(schema_contract)
        end

        def schema_contract
          {
            task_schema: label_for(config.fetch(:task_schema)),
            worker_output_schema: label_for(config.fetch(:worker_output_schema)),
            final_output_schema: label_for(config.fetch(:final_output_schema))
          }
        end

        def decision_contract
          {
            shape: :hash,
            exactly_one_of: %i[tasks final stop],
            tasks_limit: config.fetch(:max_workers)
          }
        end

        def output_contract
          {
            success: :final_output_schema,
            worker_result_shape: :execution_id_task_output,
            failure: :workflow_error_on_stop_exhaustion_or_schema_violation
          }
        end

        def resume_contract
          {
            granularity: :transition,
            round_checkpointing: false,
            worker_checkpointing: false,
            idempotency_mode: idempotency_mode,
            in_flight_resume: in_flight_resume
          }
        end
      end
    end
  end
end
