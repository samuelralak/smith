# frozen_string_literal: true

module Smith
  class Workflow
    module ExecutionBindingResolution
      private

      def resolve_registered_agent!(name, workflow_class:, transition_name:, role:)
        authorization = @split_step_active_execution_authorization
        return authorization.fetch_agent!(name, workflow_class:, transition_name:, role:) if authorization

        Agent::Registry.fetch!(name, workflow_class:, transition_name:, role:)
      end

      def resolve_agent_class(transition)
        parallel_binding = Thread.current[:smith_parallel_agent_binding]
        parallel_agent_class = parallel_binding&.resolve(workflow: self, transition:)
        return parallel_agent_class if parallel_agent_class

        transition.agent_name && resolve_registered_agent!(
          transition.agent_name,
          workflow_class: self.class,
          transition_name: transition.name,
          role: :agent
        )
      end
    end
  end
end
