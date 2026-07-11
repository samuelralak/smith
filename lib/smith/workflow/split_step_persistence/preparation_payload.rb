# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module PreparationPayload
        private

        def capture_split_step_preparation_payload!(payload, next_version)
          validate_split_step_marker!(payload, expected: true)
          prepared_payload = split_step_preparation_payload(payload)
          @split_step_preparation_payload = prepared_payload
          @split_step_preparation_digest = CanonicalPayloadDigest.call(prepared_payload)
          descriptor_builder = PreparationClaim.instance_method(:build_split_step_prepared_descriptor)
          @split_step_pending_descriptor = descriptor_builder.bind_call(self, next_version)
          prepared_payload
        rescue StandardError
          resetter = PreparationRecovery.instance_method(:reset_failed_split_step_preparation!)
          resetter.bind_call(self)
          raise
        end
      end
    end
  end
end
