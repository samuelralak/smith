# frozen_string_literal: true

require "digest"

require_relative "store_rules"

module Smith
  module Artifacts
    # An artifact store in the process: for one process and for tests.
    # Refs are content hashes, so runs that store the same bytes share one;
    # each run's claim on it (and when it made the claim) is kept apart, so
    # a run's delete drops only its own claim, and the bytes go with the
    # last claim.
    class Memory
      include StoreRules

      INNER_REF = /\A\h{64}\z/
      HOST = :host
      private_constant :HOST

      attr_reader :namespace

      def initialize(namespace: nil)
        @namespace = check_namespace!(namespace)
        @store = {}
        @metadata = {}
      end

      def store(data, content_type: "application/octet-stream", execution_namespace: nil)
        enforce_tenant_isolation!
        check_data!(data)
        ref = generate_ref(Digest::SHA256.hexdigest(data))
        @store[ref] = data
        meta = (@metadata[ref] ||= { content_type:, claims: {} })
        meta[:claims][execution_namespace || HOST] = Time.now.utc
        ref
      end

      def fetch(ref)
        enforce_tenant_isolation!
        @store[ref] if owns_ref?(ref)
      end

      # Drops a run's claim (or, with no run named, every claim); the bytes
      # go when no claim is left.
      def delete(ref, execution_namespace: nil)
        enforce_tenant_isolation!
        meta = @metadata[ref] if owns_ref?(ref)
        return unless meta

        execution_namespace ? meta[:claims].delete(execution_namespace) : meta[:claims].clear
        return unless meta[:claims].empty?

        @store.delete(ref)
        @metadata.delete(ref)
        nil
      end

      # Whether a run (its execution namespace) stored this ref.
      def stored_by?(ref, execution_namespace)
        return false if execution_namespace.nil? || !owns_ref?(ref)

        @metadata.dig(ref, :claims)&.key?(execution_namespace) || false
      end

      # Refs whose claims (or the run's claim, when one is named) are all
      # older than the retention.
      def expired(retention: nil, execution_namespace: nil)
        retention = effective_retention(retention)
        return [] unless retention

        cutoff = Time.now.utc - retention
        @metadata.filter_map do |ref, meta|
          ref if owns_ref?(ref) && claims_before?(meta[:claims], execution_namespace, cutoff)
        end
      end

      private

      def claims_before?(claims, execution_namespace, cutoff)
        claims = claims.slice(execution_namespace) if execution_namespace
        !claims.empty? && claims.values.all? { |stored_at| stored_at < cutoff }
      end
    end
  end
end
