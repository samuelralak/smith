# frozen_string_literal: true

require "digest"

module Smith
  module Artifacts
    class Memory
      attr_reader :namespace

      def initialize(namespace: nil)
        @namespace = namespace
        @store = {}
        @metadata = {}
      end

      def store(data, content_type: "application/octet-stream", execution_namespace: nil)
        enforce_tenant_isolation!
        ref = generate_ref(data)
        @store[ref] = data
        @metadata[ref] ||= { content_type: content_type, stored_at: Time.now.utc, execution_namespaces: [] }
        tag_execution_namespace(ref, execution_namespace)
        ref
      end

      def fetch(ref)
        enforce_tenant_isolation!
        return nil unless owns_ref?(ref)

        @store[ref]
      end

      def expired(retention: nil, execution_namespace: nil)
        effective_retention = retention || Smith.config.artifact_retention
        return [] unless effective_retention

        cutoff = Time.now.utc - effective_retention
        @metadata.select { |ref, meta| expired_match?(ref, meta, cutoff, execution_namespace) }.keys
      end

      private

      def tag_execution_namespace(ref, execution_namespace)
        return unless execution_namespace

        namespaces = @metadata[ref][:execution_namespaces]
        namespaces << execution_namespace unless namespaces.include?(execution_namespace)
      end

      def expired_match?(ref, meta, cutoff, execution_namespace)
        owns_ref?(ref) &&
          meta[:stored_at] < cutoff &&
          (execution_namespace.nil? || meta[:execution_namespaces]&.include?(execution_namespace))
      end

      def generate_ref(data)
        content_hash = Digest::SHA256.hexdigest(data.to_s)
        @namespace ? "#{@namespace}:#{content_hash}" : content_hash
      end

      def owns_ref?(ref)
        if @namespace
          ref.start_with?("#{@namespace}:")
        else
          !ref.include?(":")
        end
      end

      def enforce_tenant_isolation!
        return unless Smith.config.artifact_tenant_isolation

        raise Smith::Error, "artifact_tenant_isolation requires a namespace" unless @namespace
      end
    end
  end
end
