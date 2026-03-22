# frozen_string_literal: true

require "securerandom"

module Smith
  class Workflow
    module ArtifactIntegration
      private

      def with_scoped_artifacts
        if @inherited_scoped_artifacts
          Smith.scoped_artifacts = @inherited_scoped_artifacts
        else
          backend = Smith.config.artifact_store || Smith.artifacts
          Smith.scoped_artifacts = Artifacts::ScopedStore.new(backend: backend, namespace: execution_namespace)
        end
        yield
      end

      def execution_namespace
        @execution_namespace ||= SecureRandom.uuid
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
