# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module Payloads
        private

        def persisted_split_step_payload?(payload, expected)
          return false unless payload

          JSON.parse(payload) == JSON.parse(expected)
        rescue JSON::ParserError, TypeError
          false
        end

        def persisted_split_step_checkpoint?(payload)
          return false unless payload && @split_step_checkpoint_digest

          @split_step_checkpoint_digest == Digest::SHA256.hexdigest(payload)
        end

        def validate_split_step_marker!(payload, expected:)
          marker = JSON.parse(payload).fetch("step_in_progress")
          return if marker == expected

          raise WorkflowError, "split-step persistence serialized an invalid step_in_progress marker"
        rescue JSON::ParserError, KeyError, TypeError
          raise WorkflowError, "split-step persistence requires an explicit step_in_progress marker"
        end

        def split_step_checkpoint_payload(payload)
          document = JSON.parse(payload)
          document["step_in_progress"] = false
          JSON.generate(document)
        end

        def split_step_preparation_payload(payload)
          document = JSON.parse(payload)
          document["split_step_token"] = @split_step_token
          if restart_safe_split_step?
            document["split_step_phase"] = "prepared"
            document["split_step_persistence_identity"] = @split_step_adapter.persistence_identity
          end
          JSON.generate(document)
        end

        def split_step_transition_signature(transition)
          transition && TransitionContract.signature(transition)
        end
      end
    end
  end
end
