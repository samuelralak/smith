# frozen_string_literal: true

module Smith
  class Workflow
    class Transition
      attr_reader :name, :from, :to, :agent_name, :agent_opts, :success_transition, :failure_transition,
                  :router_config, :workflow_class

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

      def nested?
        !@workflow_class.nil?
      end

      def routed?
        !@router_config.nil?
      end

      def parallel?
        agent_opts&.dig(:parallel) == true
      end
    end
  end
end
