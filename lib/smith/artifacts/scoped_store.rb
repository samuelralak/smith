# frozen_string_literal: true

module Smith
  module Artifacts
    # A run's view of the artifact store: it stores under its own
    # namespace, and reads its own refs and those of the namespaces it may
    # read (a child run's parent and that parent's ancestors).
    class ScopedStore
      def initialize(backend:, namespace:, readable: [])
        @backend = backend
        @namespace = namespace
        @readable = [namespace, *readable].freeze
      end

      def store(data, content_type: "application/octet-stream")
        inner_ref = @backend.store(data, content_type: content_type, execution_namespace: @namespace)
        "#{@namespace}:#{inner_ref}"
      end

      def fetch(ref)
        namespace = @readable.find { |candidate| ref.start_with?("#{candidate}:") }
        return nil unless namespace

        @backend.fetch(ref.delete_prefix("#{namespace}:"))
      end

      def expired(retention: nil)
        @backend.expired(retention: retention, execution_namespace: @namespace)
                .map { |ref| "#{@namespace}:#{ref}" }
      end
    end
  end
end
