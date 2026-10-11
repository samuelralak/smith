# frozen_string_literal: true

module Smith
  module Artifacts
    # A run's view of the artifact store: it stores under its own
    # namespace, and reads its own refs and those of the namespaces it may
    # read (a child run's parent and that parent's ancestors). A store that
    # records who stored a ref (`stored_by?`, as every built-in store does)
    # is asked, so a ref names an artifact one of those runs stored and no
    # other; with any other store the namespace prefix alone decides a read,
    # and a delete is refused.
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
        return unless ref.is_a?(String)

        namespace = @readable.find { |candidate| ref.start_with?("#{candidate}:") }
        return nil unless namespace

        inner = ref.delete_prefix("#{namespace}:")
        return nil if vouches? && !backend.stored_by?(inner, namespace)

        backend.fetch(inner)
      end

      # Removes one of this run's own refs (never a readable ancestor's or
      # another run's): only through a store that can tell which run stored
      # a ref. A store whose delete takes the run (every built-in one) is
      # asked to remove only what this run stored, and Memory drops only
      # this run's claim on bytes other runs share; any other store deletes
      # a ref this run stored.
      def delete(ref)
        unless vouches? && backend.respond_to?(:delete)
          raise Smith::Error, "deleting a run's artifact needs a store with stored_by? and delete"
        end
        return unless ref.is_a?(String)

        inner = ref.delete_prefix("#{@namespace}:")
        if per_run_delete? then backend.delete(inner, execution_namespace: @namespace)
        elsif backend.stored_by?(inner, @namespace) then backend.delete(inner)
        end
        nil
      end

      # Whether the store can tell which run stored a ref.
      def vouches? = backend.respond_to?(:stored_by?)

      def expired(retention: nil)
        raise Smith::Error, "the artifact store does not list expired refs" unless backend.respond_to?(:expired)

        backend.expired(retention: retention, execution_namespace: @namespace).map { |ref| "#{@namespace}:#{ref}" }
      end

      private

      def backend = @backend ||= Smith.artifact_backend

      def per_run_delete?
        backend.method(:delete).parameters.any? do |kind, name|
          %i[key keyreq].include?(kind) && name == :execution_namespace
        end
      end
    end
  end
end
