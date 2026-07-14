# frozen_string_literal: true

require_relative "replace_exact_signature"

module Smith
  class Workflow
    module SplitStepPersistence
      module RestartSafeAdapter
        private

        def validate_restart_safe_adapter!(adapter)
          return unless restart_safe_split_step?

          ensure_replace_exact_capability!(adapter)
          ensure_replace_exact_signature!(adapter)
          ensure_persistence_identity!(adapter)
        end

        def ensure_replace_exact_capability!(adapter)
          return if Smith::PersistenceAdapters.supports?(adapter, :replace_exact)

          raise WorkflowError, "restart-safe split-step persistence requires replace_exact"
        end

        def ensure_replace_exact_signature!(adapter)
          return if ReplaceExactSignature.new(adapter.method(:replace_exact)).valid?

          raise WorkflowError,
                "restart-safe split-step persistence requires replace_exact(key, payload, expected_payload:, ttl:)"
        end

        def ensure_persistence_identity!(adapter)
          identity = adapter.persistence_identity if
            Smith::PersistenceAdapters.supports?(adapter, :persistence_identity)
          return if identity.is_a?(String) && !identity.empty? && identity.bytesize <= 256

          raise WorkflowError, "restart-safe split-step persistence requires a bounded persistence_identity"
        end
      end
    end
  end
end
