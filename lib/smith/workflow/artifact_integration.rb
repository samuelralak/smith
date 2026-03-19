# frozen_string_literal: true

module Smith
  class Workflow
    module ArtifactIntegration
      private

      def with_scoped_artifacts
        Smith.scoped_artifacts = Artifacts::Memory.new(namespace: execution_namespace)
        yield
      end

      def execution_namespace
        @execution_namespace ||= "#{self.class.name || "workflow"}:#{object_id}"
      end

      def propagate_scoped_artifacts
        Smith.scoped_artifacts
      end

      def build_session
        manager = self.class.context_manager
        return nil unless manager

        Context::Session.new(
          messages: @session_messages ||= [],
          context_manager: manager,
          persisted_context: @context
        )
      end
    end
  end
end
