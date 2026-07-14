# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module Recovery
        private

        def recover_prepared_step(recovery, adapter)
          decision = validate_prepared_step_recovery!(recovery)
          descriptor = decision.prepared_step
          store = persistence_adapter!(adapter)
          ensure_strict_split_step_persistence!
          validate_split_step_adapter!(store)
          ensure_recovery_outside_transaction!(store)
          payload = fetch_recovery_payload!(store, descriptor.persistence_key)
          document = validate_recovery_payload!(payload, decision, store)
          restore_state(document, allow_step_in_progress: true)
          attach_recovered_split_step!(descriptor, payload, store, dispatch_claim: decision.dispatch_claim)
          self
        end

        def validate_prepared_step_recovery!(recovery)
          return recovery if recovery.is_a?(PreparedStepRecovery)

          raise ArgumentError, "recovery must be a Smith::Workflow::PreparedStepRecovery"
        end

        def ensure_recovery_outside_transaction!(adapter)
          return unless Smith::PersistenceAdapters.supports?(adapter, :transaction_open?)
          return unless adapter.transaction_open?

          raise WorkflowError, "prepared-step recovery requires committed host authority outside a transaction"
        end

        def fetch_recovery_payload!(adapter, key)
          payload = adapter.fetch(key)
          return payload if payload.is_a?(String)

          raise WorkflowError, "the persisted split-step preparation is not available"
        end

        def validate_recovery_payload!(payload, decision, adapter)
          if payload.bytesize > CanonicalPayloadDigest::MAX_BYTES
            raise WorkflowError,
                  "persisted split-step preparation exceeds maximum bytes #{CanonicalPayloadDigest::MAX_BYTES}"
          end

          document = JSON.parse(payload)
          raise WorkflowError, "the persisted split-step preparation must be an object" unless document.is_a?(Hash)

          validate_recovery_definition!(document, decision.prepared_step)
          validate_recovery_identity!(document, decision, adapter)
          validate_recovery_digest!(payload, decision)
          document
        rescue JSON::ParserError, TypeError
          raise WorkflowError, "the persisted split-step preparation is invalid"
        end

        def validate_recovery_definition!(document, descriptor)
          current_digest = self.class.definition_digest
          return if recovery_digests_match?(document, descriptor, current_digest) &&
                    recovery_class_matches?(document) && recovery_schema_matches?(document)

          raise WorkflowError, "the prepared step does not match the current workflow definition"
        end

        def recovery_digests_match?(document, descriptor, current_digest)
          current_digest &&
            descriptor.definition_digest == current_digest &&
            document["definition_digest"] == current_digest
        end

        def recovery_class_matches?(document)
          !self.class.name.to_s.empty? && document["class"] == self.class.name
        end

        def recovery_schema_matches?(document)
          document["schema_version"] == self.class.persistence_schema_version
        end

        def validate_recovery_identity!(document, decision, adapter)
          descriptor = decision.prepared_step
          return if recovery_marker_matches?(document, decision, adapter) &&
                    recovery_position_matches?(document, descriptor)

          raise WorkflowError, "the persisted split-step preparation does not match the recovery descriptor"
        end

        def recovery_marker_matches?(document, decision, adapter)
          descriptor = decision.prepared_step
          document["step_in_progress"] == true &&
            recovery_phase_matches?(document, decision.dispatch_claim) &&
            document["split_step_persistence_identity"] == adapter.persistence_identity &&
            document["split_step_token"] == descriptor.token &&
            document["persistence_key"] == descriptor.persistence_key &&
            document["persistence_version"] == descriptor.persistence_version
        end

        def recovery_phase_matches?(document, dispatch_claim)
          if dispatch_claim
            document["split_step_phase"] == "dispatching" &&
              document["split_step_dispatch_token"] == dispatch_claim.token
          else
            document["split_step_phase"] == "prepared" && !document.key?("split_step_dispatch_token")
          end
        end

        def recovery_position_matches?(document, descriptor)
          step_count = document["step_count"]
          step_count.is_a?(Integer) &&
            step_count + 1 == descriptor.step_number &&
            document["state"].to_s == descriptor.from
        end

        def validate_recovery_digest!(payload, decision)
          expected = decision.dispatch_claim&.dispatch_digest || decision.prepared_step.preparation_digest
          return if CanonicalPayloadDigest.call(payload) == expected

          raise WorkflowError, "the persisted split-step recovery payload digest does not match"
        end
      end
    end
  end
end
