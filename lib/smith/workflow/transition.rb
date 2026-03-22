# frozen_string_literal: true

module Smith
  class Workflow
    class Transition
      attr_reader :name, :from, :to, :agent_name, :agent_opts, :success_transition, :failure_transition,
                  :router_config, :workflow_class, :optimization_config

      def initialize(name, from:, to:, &)
        @name = name
        @from = from
        @to = to
        instance_eval(&) if block_given?
      end

      def execute(agent_name, **opts)
        @agent_name = agent_name
        @agent_opts = opts
      end

      def on_success(transition_name)
        @success_transition = transition_name
      end

      def on_failure(transition_name)
        @failure_transition = transition_name
      end

      def route(agent_name, routes:, confidence_threshold:, fallback:)
        @agent_name = agent_name
        @router_config = { routes: routes, confidence_threshold: confidence_threshold, fallback: fallback }
      end

      def workflow(klass)
        raise WorkflowError, "workflow binding must be a Class" unless klass.is_a?(Class)
        raise WorkflowError, "workflow binding must be a Smith::Workflow subclass" unless klass < Workflow
        raise WorkflowError, "transition cannot declare both workflow and execute" if @agent_name && !@router_config
        raise WorkflowError, "transition cannot declare both workflow and route" if @router_config

        @workflow_class = klass
      end

      def optimize(generator:, evaluator:, max_rounds:, evaluator_schema:, improvement_threshold: nil)
        validate_optimize_conflicts!
        validate_optimize_controls!(generator, evaluator, max_rounds, evaluator_schema)

        @optimization_config = {
          generator: generator, evaluator: evaluator, max_rounds: max_rounds,
          evaluator_schema: evaluator_schema, improvement_threshold: improvement_threshold
        }
      end

      def optimized?
        !@optimization_config.nil?
      end

      def nested?
        !@workflow_class.nil?
      end

      def routed?
        !@router_config.nil?
      end

      def parallel?
        agent_opts&.dig(:parallel) == true
      end

      private

      def validate_optimize_conflicts!
        raise WorkflowError, "transition cannot declare both optimize and execute" if @agent_name && !@router_config
        raise WorkflowError, "transition cannot declare both optimize and route" if @router_config
        raise WorkflowError, "transition cannot declare both optimize and workflow" if @workflow_class
      end

      def validate_optimize_controls!(generator, evaluator, max_rounds, evaluator_schema)
        raise WorkflowError, "optimize requires a generator" if generator.nil?
        raise WorkflowError, "optimize requires an evaluator" if evaluator.nil?
        raise WorkflowError, "optimize requires an evaluator_schema" if evaluator_schema.nil?

        return if max_rounds.is_a?(Integer) && max_rounds.positive?

        raise WorkflowError, "optimize max_rounds must be a positive integer"
      end
    end
  end
end
