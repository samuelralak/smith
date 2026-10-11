# frozen_string_literal: true

module Smith
  module Artifacts
    # A run's view of the artifact store: it stores under its own
    # namespace, and reads its own refs and those of the namespaces it may
    # read (a child run's parent and that parent's ancestors). A store that
    # records who stored a ref (`stored_by?`, as Memory and File do) is
    # asked, so a ref names an artifact one of those runs stored and no
    # other; with any other store the namespace prefix alone decides.
    # Without a `backend:`, the configured store is resolved when a step
    # first stores or reads, so a run that keeps no artifacts needs none.
    class ScopedStore
      def initialize(namespace:, backend: nil, readable: [])
        @backend = backend
        @namespace = namespace
        @readable = [namespace, *readable].freeze
      end

      def store(data, content_type: "application/octet-stream")
        inner_ref = backend.store(data, content_type: content_type, execution_namespace: @namespace)
        "#{@namespace}:#{inner_ref}"
      end

      def fetch(ref)
        namespace = @readable.find { |candidate| ref.start_with?("#{candidate}:") }
        return nil unless namespace

        inner = ref.delete_prefix("#{namespace}:")
        return nil if vouches? && !backend.stored_by?(inner, namespace)

        backend.fetch(inner)
      end

      # Removes one of this run's own refs (never a readable ancestor's).
      def delete(ref)
        return unless ref.start_with?("#{@namespace}:") && backend.respond_to?(:delete)

        inner = ref.delete_prefix("#{@namespace}:")
        backend.delete(inner) if !vouches? || backend.stored_by?(inner, @namespace)
        nil
      end

      # Whether the store can tell which run stored a ref.
      def vouches? = backend.respond_to?(:stored_by?)

      def expired(retention: nil)
        backend.expired(retention: retention, execution_namespace: @namespace).map { |ref| "#{@namespace}:#{ref}" }
      end

      private

      def backend = @backend ||= Smith.artifact_backend
    end
  end
end
