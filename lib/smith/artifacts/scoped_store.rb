# frozen_string_literal: true

require "digest"

module Smith
  module Artifacts
    class ScopedStore
      def initialize(backend:, namespace:)
        @backend = backend
        @namespace = namespace
      end

      def store(data, content_type: "application/octet-stream")
        ref = @backend.store(data, content_type: content_type)
        "#{@namespace}:#{ref}"
      end

      def fetch(ref)
        return nil unless ref.start_with?("#{@namespace}:")

        inner_ref = ref.delete_prefix("#{@namespace}:")
        @backend.fetch(inner_ref)
      end

      def expired(retention: nil)
        @backend.expired(retention: retention).map { |ref| "#{@namespace}:#{ref}" }
      end
    end
  end
end
