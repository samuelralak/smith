# frozen_string_literal: true

module Smith
  class Workflow
    module TransitionActionability
      module_function

      def call(transition)
        [
          transition.agent_name,
          transition.deterministic?,
          transition.routed?,
          transition.fanout?,
          transition.nested?,
          transition.optimized?,
          transition.orchestrated?,
          transition.awaits?,
          transition.child_runs?,
          transition.success_transition
        ].any?
      end
    end
  end
end
