# frozen_string_literal: true

require "securerandom"

module Smith
  module Artifacts
    class Memory
      def initialize(namespace: nil)
        @namespace = namespace
        @store = {}
        @metadata = {}
      end

      def store(data, content_type: "application/octet-stream")
        ref = generate_ref
        @store[ref] = data
        @metadata[ref] = { content_type: content_type, stored_at: Time.now.utc }
        ref
      end

      def fetch(ref)
        @store[ref]
      end

      def expired(retention: nil)
        return [] unless retention

        cutoff = Time.now.utc - retention
        @metadata.select { |_, meta| meta[:stored_at] < cutoff }.keys
      end

      private

      def generate_ref
        raw = SecureRandom.uuid
        @namespace ? "#{@namespace}:#{raw}" : raw
      end
    end
  end
end
