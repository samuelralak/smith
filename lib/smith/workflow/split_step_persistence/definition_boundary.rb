# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module DefinitionBoundary
        private

        def restart_safe_split_step? = !effective_definition_digest.nil?

        def ensure_split_step_definition_current!
          return if effective_definition_digest == self.class.definition_digest

          raise WorkflowError, "the prepared workflow definition has changed"
        end
      end
    end
  end
end
