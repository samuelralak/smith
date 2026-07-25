# frozen_string_literal: true

require_relative "completion_usage_recording"
require_relative "usage_entry_recording"

module Smith
  class Agent
    module UsageTracking
      include CompletionUsageRecording
      include UsageEntryRecording

      private

      def account_failed_attempt(error, model_reference, agent_class)
        return unless error.respond_to?(:input_tokens) && error.respond_to?(:output_tokens)

        input = error.input_tokens
        output = error.output_tokens
        return unless input.is_a?(Integer) && output.is_a?(Integer)

        record_failed_usage(agent_class, model_reference, input, output, :failed_attempt)
      end

      def account_completed_prefix(agent_class, model_reference, messages)
        completion = Completion.from_messages(response: nil, messages: messages)
        record_completion_usage(agent_class, completion, :partial_attempt, model_reference)
      end

      def record_failed_usage(agent_class, model_reference, input_tokens, output_tokens, attempt_kind)
        model_reference = coerce_model_reference(model_reference)
        cost = Smith::Pricing.compute_cost(
          model: model_reference.model_id,
          provider: model_reference.provider,
          input_tokens:,
          output_tokens:
        )
        agent_result = Workflow::AgentResult.new(
          content: nil,
          input_tokens:,
          output_tokens:,
          cost: cost,
          model_used: model_reference.model_id,
          provider_used: model_reference.provider
        )
        Thread.current[:smith_failed_agent_results] ||= []
        Thread.current[:smith_failed_agent_results] << agent_result
        record_usage(agent_class, agent_result, attempt_kind, model_reference)
      end

      def snapshot_and_finalize(agent_class, completion, model_reference)
        model_reference = coerce_model_reference(model_reference)
        agent_result = Workflow::AgentResult.new(
          content: completion.content,
          input_tokens: completion.input_tokens,
          output_tokens: completion.output_tokens,
          cost: nil,
          model_used: model_reference.model_id,
          provider_used: model_reference.provider
        )
        Thread.current[:smith_last_agent_result] = agent_result
        emit_token_usage(agent_result)
        compute_agent_cost(agent_result)
        record_completion_usage(agent_class, completion, :completed_attempt, model_reference)

        agent_result.content = run_after_completion(agent_class, agent_result.content, @context)
        raise_blank_output!(agent_class, agent_result)
        agent_result
      end

      def raise_blank_output!(agent_class, agent_result)
        return unless blank_agent_output?(agent_result.content)

        raise Smith::BlankAgentOutputError.new(
          agent_name: agent_class.register_as,
          model_used: agent_result.model_used
        )
      end

      def blank_agent_output?(content)
        return true if content.nil?
        return content.strip.empty? if content.is_a?(String)

        false
      end

      def emit_token_usage(agent_result)
        return unless agent_result.usage_known?

        Smith::Trace.record(
          type: :token_usage,
          data: {
            input_tokens: agent_result.input_tokens,
            output_tokens: agent_result.output_tokens,
            model: agent_result.model_used,
            provider: agent_result.provider_used
          }.compact
        )
      end

      def compute_agent_cost(agent_result)
        return unless agent_result.usage_known?

        model = agent_result.model_used
        agent_result.cost = Smith::Pricing.compute_cost(
          model: model,
          provider: agent_result.provider_used,
          input_tokens: agent_result.input_tokens,
          output_tokens: agent_result.output_tokens
        )
      end
    end
  end
end
