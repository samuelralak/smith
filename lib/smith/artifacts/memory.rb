# frozen_string_literal: true

require "securerandom"

module Smith
  module Artifacts
    class Memory
      attr_reader :namespace

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
        return nil unless owns_ref?(ref)

        @store[ref]
      end

      def expired(retention: nil)
        return [] unless retention

        cutoff = Time.now.utc - retention
        @metadata.select { |ref, meta| owns_ref?(ref) && meta[:stored_at] < cutoff }.keys
      end

      private

      def generate_ref
        raw = SecureRandom.uuid
        @namespace ? "#{@namespace}:#{raw}" : raw
      end

      def owns_ref?(ref)
        if @namespace
          ref.start_with?("#{@namespace}:")
        else
          !ref.include?(":")
        end
      end
    end
  end
end
