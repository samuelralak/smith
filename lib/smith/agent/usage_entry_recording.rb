# frozen_string_literal: true

module Smith
  class Agent
    module UsageEntryRecording
      private

      def record_usage(agent_class, agent_result, attempt_kind, model_reference)
        return unless agent_result.usage_known?

        model_reference = coerce_model_reference(model_reference)
        entry = build_usage_entry(agent_class, agent_result, attempt_kind, model_reference)
        accumulate_usage(agent_result, entry)
      end

      def build_usage_entry(agent_class, agent_result, attempt_kind, model_reference)
        Workflow::UsageEntry.new(
          usage_id: SecureRandom.uuid,
          agent_name: agent_class.register_as,
          model: model_reference.model_id,
          provider: model_reference.provider,
          input_tokens: agent_result.input_tokens,
          output_tokens: agent_result.output_tokens,
          cost: agent_result.cost,
          attempt_kind: attempt_kind,
          recorded_at: Time.now.utc.iso8601
        )
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
