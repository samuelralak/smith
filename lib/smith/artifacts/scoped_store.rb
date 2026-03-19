# frozen_string_literal: true

module Smith
  module Artifacts
    class ScopedStore
      def initialize(backend:, namespace:)
        @backend = backend
        @namespace = namespace
        @owned_refs = []
      end

      def store(data, content_type: "application/octet-stream")
        inner_ref = @backend.store(data, content_type: content_type)
        @owned_refs << inner_ref
        "#{@namespace}:#{inner_ref}"
      end

      def fetch(ref)
        return nil unless ref.start_with?("#{@namespace}:")

        inner_ref = ref.delete_prefix("#{@namespace}:")
        @backend.fetch(inner_ref)
      end

      def expired(retention: nil)
        backend_expired = @backend.expired(retention: retention)
        owned_expired = backend_expired & @owned_refs
        owned_expired.map { |ref| "#{@namespace}:#{ref}" }
      end
    end
  end
end
