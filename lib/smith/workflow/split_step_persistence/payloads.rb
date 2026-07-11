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
          return false unless payload && @split_step_checkpoint_digests

          @split_step_checkpoint_digests.include?(Digest::SHA256.hexdigest(payload))
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
          JSON.generate(document)
        end

        def split_step_transition_signature(transition)
          return unless transition

          transition.instance_variables.sort.map do |name|
            [name, split_step_signature_value(transition.instance_variable_get(name))]
          end
        end

        def split_step_signature_value(value)
          case value
          when Hash
            value.map { |key, item| [split_step_signature_value(key), split_step_signature_value(item)] }
          when Array
            value.map { |item| split_step_signature_value(item) }
          when String
            value.dup.freeze
          when Symbol, Numeric, true, false, nil
            value
          else
            [value.class.name, value.object_id]
          end
        end

        def deep_freeze_split_step_value(value)
          case value
          when Hash
            value.each do |key, item|
              deep_freeze_split_step_value(key)
              deep_freeze_split_step_value(item)
            end
          when Array, Set
            value.each { |item| deep_freeze_split_step_value(item) }
          when Module
            return value
          end
          value&.freeze
        end
      end
    end
  end
end
