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
    end
  end
end
