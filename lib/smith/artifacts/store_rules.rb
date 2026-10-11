# frozen_string_literal: true

module Smith
  module Artifacts
    # What every built-in store holds to: a tenant `namespace:` of letters,
    # digits, `-` and `_` (so its refs stay readable), the
    # `artifact_tenant_isolation` setting (refuse to work without a
    # namespace), refs that are the store's own (its tenant's prefix, then
    # the store's ref shape, nothing else), the `artifact_retention`
    # setting when no retention is given, and no run behind a ref whose run
    # is not named.
    module StoreRules
      NAMESPACE = /\A[A-Za-z0-9_-]+\z/
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      private

      def check_namespace!(namespace)
        return namespace if namespace.nil? || (namespace.is_a?(String) && NAMESPACE.match?(namespace))

        raise ArgumentError, "an artifact store's namespace: must be letters, digits, - and _"
      end

      def enforce_tenant_isolation!
        return unless Smith.config.artifact_tenant_isolation

        raise Smith::Error, "artifact_tenant_isolation requires a namespace" unless @namespace
      end

      # The store's tenant prefix, then a ref of the store's shape.
      def owns_ref?(ref)
        return false unless ref.is_a?(String)

        inner = @namespace ? ref.delete_prefix("#{@namespace}:") : ref
        (!@namespace || inner != ref) && self.class::INNER_REF.match?(inner)
      end

      def effective_retention(retention) = retention || Smith.config.artifact_retention

      # An artifact is bytes: other values would be stored as whatever a
      # store makes of them (Ruby's inspect, or a refusal).
      def check_data!(data)
        raise TypeError, "an artifact is bytes (a String); serialize other values first" unless data.is_a?(String)
      end

      def generate_ref(raw) = @namespace ? "#{@namespace}:#{raw}" : raw
    end
  end
end
