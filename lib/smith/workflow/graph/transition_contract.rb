# frozen_string_literal: true

require "dry-initializer"

require_relative "transition_contract_attributes"

module Smith
  class Workflow
    class Graph
      class TransitionContract
        extend Dry::Initializer

        option :name
        option :definition_index
        option :from
        option :to
        option :agent_name, default: proc {}
        option :success_transition, default: proc {}
        option :failure_transition, default: proc {}
        option :router_config, default: proc {}
        option :workflow_class, default: proc {}
        option :optimization_config, default: proc {}
        option :orchestrator_config, default: proc {}
        option :fanout_config, default: proc {}
        option :retry_config, default: proc {}
        option :await_config, default: proc {}
        option :timeout_transition, default: proc {}
        option :step_input, default: proc { false }
        option :output_to, default: proc {}
        option :stream, default: proc {}
        option :batch_mode, default: proc {}
        option :children_config, default: proc {}
        option :deterministic_kind, default: proc {}
        option :deterministic_routes, default: proc {}
        option :deterministic_fallthrough, default: proc { false }
        option :deterministic, default: proc { false }
        option :parallel, default: proc { false }
        option :parallel_count, default: proc {}

        def self.from_transition(transition, identifiers:, definition_index:)
          attributes = TransitionContractAttributes.new(transition, identifiers:).to_h
          new(**attributes, definition_index:).freeze
        end

        def deterministic? = deterministic
        def orchestrated? = !orchestrator_config.nil?
        def fanout? = !fanout_config.nil?
        def optimized? = !optimization_config.nil?
        def nested? = !workflow_class.nil?
        def routed? = !router_config.nil?
        def parallel? = parallel
        def awaits? = !await_config.nil?
        def delay? = await_config&.fetch(:kind) == :delay
        def agent_step? = !agent_name.nil? || optimized? || orchestrated? || fanout?
        def child_runs? = !children_config.nil?
        def spawns? = children_config&.fetch(:kind) == :spawn
        def batches? = !batch_mode.nil? && batch_mode != :sync

        # The workflow class this step runs: nested in process, or launched
        # as runs of their own.
        def target_workflow_class = workflow_class || children_config&.fetch(:workflow)
      end
    end
  end
end
