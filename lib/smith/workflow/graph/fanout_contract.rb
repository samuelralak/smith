# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      class FanoutContract
        attr_reader :transition, :workflow_class

        def self.from_transition(transition, workflow_class: nil)
          branches = transition.fanout_config&.fetch(:branches, nil)
          return unless branches

          new(transition, workflow_class: workflow_class).to_h
        end

        def initialize(transition, workflow_class: nil)
          @transition = transition
          @workflow_class = workflow_class
        end

        def to_h
          deep_freeze(
            branch_count: branches.length,
            join_state: immutable_value(transition.to),
            output_shape: :named_branch_results,
            branch_order: :declaration_order,
            join: join_contract,
            output_contract: output_contract,
            resume_contract: resume_contract,
            branches: branch_summaries,
            branch_contracts: branch_contracts
          )
        end

        private

        def branches
          transition.fanout_config.fetch(:branches)
        end

        def join_contract
          {
            state: immutable_value(transition.to),
            transition: immutable_value(transition.name)
          }
        end

        def output_contract
          {
            collection: :array,
            item_shape: :named_branch_result,
            ordering: :branch_declaration_order,
            branch_key_field: :branch,
            agent_field: :agent,
            output_field: :output,
            failure: :discard_all_branch_results_on_failure
          }
        end

        def resume_contract
          {
            granularity: :transition,
            branch_checkpointing: false,
            idempotency_mode: idempotency_mode,
            in_flight_resume: in_flight_resume
          }
        end

        def branch_summaries
          branches.map do |branch, agent|
            { branch: immutable_value(branch), agent: immutable_value(agent) }
          end
        end

        def branch_contracts
          branches.map do |branch, agent|
            branch_value = immutable_value(branch)
            agent_value = immutable_value(agent)

            {
              branch: branch_value,
              agent: agent_value,
              result_branch_value: branch_value,
              result_shape: {
                branch: branch_value,
                agent: agent_value,
                output: :agent_output
              }
            }
          end
        end

        def immutable_value(value)
          return value if immediate_value?(value)

          duplicate = value.dup
          return value if duplicate.equal?(value)

          duplicate.freeze
        rescue TypeError
          # Some host-owned topology values intentionally refuse duplication.
          # Leave them untouched; the graph contract containers are still
          # frozen, and inspection must never mutate workflow-owned values.
          value
        end

        def immediate_value?(value)
          value.nil? || value.is_a?(Symbol) || value.is_a?(Numeric) ||
            value == true || value == false
        end

        def idempotency_mode
          return :unknown unless workflow_class&.respond_to?(:idempotency_mode)

          workflow_class.idempotency_mode
        end

        def in_flight_resume
          return :blocked_by_step_in_progress if idempotency_mode == :strict
          return :unknown unless %i[strict lax].include?(idempotency_mode)

          :reruns_transition
        end

        def deep_freeze(value)
          case value
          when Hash
            value.each_value { |nested| deep_freeze(nested) }
            value.freeze
          when Array
            value.each { |nested| deep_freeze(nested) }
            value.freeze
          end

          value
        end
      end
    end
  end
end
