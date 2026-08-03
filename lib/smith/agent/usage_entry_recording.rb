# frozen_string_literal: true

module Smith
  class Agent
    module UsageEntryRecording
      private

      def record_usage(agent_class, agent_result, attempt_kind, model_reference, attempt_id: nil)
        return unless agent_result.usage_known?

        model_reference = coerce_model_reference(model_reference)
        entry = build_usage_entry(agent_class, agent_result, attempt_kind, model_reference, attempt_id:)
        accumulate_usage(agent_result, entry)
      end

      # Attribution (transition, branch key, optimizer round) is read from the
      # ambient context of the recording thread, which is the thread that ran
      # the provider call: a fan-out branch records under its own overlay.
      # transition and branch_key are recorded as Symbols even when a host
      # seeded Strings through Attribution.with, because from_h symbolizes
      # them on restore: recording the same way keeps a restored entry equal
      # to the recorded one.
      def build_usage_entry(agent_class, agent_result, attempt_kind, model_reference, attempt_id: nil)
        Workflow::UsageEntry.new(
          usage_id: SecureRandom.uuid,
          agent_name: agent_class.register_as,
          model: model_reference.model_id,
          provider: model_reference.provider,
          input_tokens: agent_result.input_tokens,
          output_tokens: agent_result.output_tokens,
          cost: agent_result.cost,
          attempt_kind: attempt_kind,
          recorded_at: Time.now.utc.iso8601(6),
          attempt_id: attempt_id,
          **ambient_attribution_fields
        )
      end

      def ambient_attribution_fields
        attribution = Smith::Attribution.ambient
        {
          transition: symbolized_attribution(attribution.transition),
          branch_key: symbolized_attribution(attribution.branch_key),
          round: attribution.round,
          workflow: attribution.workflow
        }
      end

      def symbolized_attribution(value)
        value.is_a?(String) ? value.to_sym : value
      end

      def accumulate_usage(agent_result, entry)
        @usage_mutex.synchronize do
          @total_tokens = (@total_tokens || 0) + agent_result.input_tokens + agent_result.output_tokens
          @total_cost = (@total_cost || 0.0) + (agent_result.cost || 0.0)
          @usage_entries << entry
        end
      end

      def coerce_model_reference(value)
        ModelReference.coerce(value)
      end
    end
  end
end
