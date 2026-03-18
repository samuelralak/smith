# frozen_string_literal: true

module Smith
  class Workflow
    class Transition
      attr_reader :name, :from, :to, :agent_name, :agent_opts, :success_transition, :failure_transition

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

      def parallel?
        agent_opts&.dig(:parallel) == true
      end
    end
  end
end
