# frozen_string_literal: true

require "securerandom"

module Smith
  class Workflow
    module ArtifactIntegration
      # How many ancestors' artifacts a child run may read: the nearest
      # ones, so a deep recursion reads its near ancestors and no others.
      MAX_INHERITED_NAMESPACES = 16
      INHERITED_NAMESPACES = :smith_inherited_artifact_namespaces
      private_constant :INHERITED_NAMESPACES

      # Builds a child run with the namespaces whose artifacts it may read
      # in force from construction; they persist with it.
      def self.with_inherited_artifact_namespaces(namespaces)
        outer = Thread.current[INHERITED_NAMESPACES]
        Thread.current[INHERITED_NAMESPACES] = artifact_namespaces!(namespaces)
        yield
      ensure
        Thread.current[INHERITED_NAMESPACES] = outer
      end

      # At most MAX_INHERITED_NAMESPACES Strings of 1 to 256 characters.
      def self.artifact_namespaces!(namespaces)
        valid = namespaces.is_a?(Array) && namespaces.length <= MAX_INHERITED_NAMESPACES &&
                namespaces.all? { _1.is_a?(String) && _1.length.between?(1, 256) }
        raise WorkflowError, "artifact namespaces must be up to #{MAX_INHERITED_NAMESPACES} names" unless valid

        namespaces.uniq.map { _1.dup.freeze }.freeze
      end

      # Taken once, so a workflow its constructor builds does not inherit
      # them too.
      def self.take_inherited_artifact_namespaces
        namespaces = Thread.current[INHERITED_NAMESPACES]
        Thread.current[INHERITED_NAMESPACES] = nil
        namespaces || [].freeze
      end

      private

      # The step's artifacts are scoped to its run (or, in a nested
      # workflow, its parent's), over the configured store itself even when
      # the step runs inside another run's step (an inline child run),
      # resolved when the step first stores or reads. The step context's
      # snapshot restores the outer scope when the step ends.
      def with_scoped_artifacts
        Smith.scoped_artifacts = @inherited_scoped_artifacts ||
                                 Artifacts::ScopedStore.new(namespace: execution_namespace,
                                                            readable: @inherited_artifact_namespaces || [])
        yield
      end

      # What a child run of this run may read: this run's namespace, then
      # the ones it may read itself, the nearest first.
      def child_artifact_namespaces
        [execution_namespace, *(@inherited_artifact_namespaces || [])].first(MAX_INHERITED_NAMESPACES).freeze
      end

      def execution_namespace
        @execution_namespace ||= SecureRandom.uuid
      end

      def propagate_scoped_artifacts
        Smith.scoped_artifacts
      end

      def build_session
        manager = self.class.context_manager
        messages = @session_messages ||= []
        return nil if manager.nil? && messages.empty?

        Context::Session.new(
          messages: messages,
          context_manager: manager,
          persisted_context: @context,
          seed_message_count: @seed_message_count || 0,
          untrusted_keys: untrusted_context_keys
        )
      end
    end
  end
end
