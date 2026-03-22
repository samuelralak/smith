# frozen_string_literal: true

module Smith
  class Agent
    module Lifecycle
      private

      def run_after_completion(agent_class, result, context)
        return result unless agent_class.method_defined?(:after_completion)

        instance = agent_class.allocate
        instance.after_completion(result, context)
      end

      def invoke_agent(agent_class, prepared_input)
        check_deadline!
        response = complete_with_provider(agent_class, prepared_input)
        snapshot_and_finalize(agent_class, response)
      end

      def complete_with_provider(agent_class, prepared_input)
        chat = agent_class.chat
        prepared_input&.each { |msg| chat.add_message(msg) }
        chat = chat.with_schema(agent_class.output_schema) if agent_class.output_schema

        begin
          chat.complete
        rescue Smith::Error
          raise
        rescue StandardError => e
          raise Smith::AgentError, e.message
        end
      end

      def snapshot_and_finalize(agent_class, response)
        agent_result = Workflow::AgentResult.from_response(response, response&.content)
        Thread.current[:smith_last_agent_result] = agent_result
        emit_token_usage(agent_result)
        compute_agent_cost(agent_class, agent_result)
        accumulate_usage(agent_result)

        agent_result.content = run_after_completion(agent_class, agent_result.content, @context)
        agent_result
      end

      def emit_token_usage(agent_result)
        return unless agent_result.usage_known?

        Smith::Trace.record(
          type: :token_usage,
          data: { input_tokens: agent_result.input_tokens, output_tokens: agent_result.output_tokens }
        )
      end

      def compute_agent_cost(agent_class, agent_result)
        return unless agent_result.usage_known?

        model = agent_class.chat_kwargs[:model]
        agent_result.cost = Smith::Pricing.compute_cost(
          model: model, input_tokens: agent_result.input_tokens, output_tokens: agent_result.output_tokens
        )
      end

      def accumulate_usage(agent_result)
        if agent_result.usage_known?
          @usage_mutex ||= Mutex.new
          @usage_mutex.synchronize do
            @token_accumulator = (@token_accumulator || 0) + agent_result.input_tokens + agent_result.output_tokens
          end
        end

        return unless agent_result.cost

        @usage_mutex ||= Mutex.new
        @usage_mutex.synchronize { @cost_accumulator = (@cost_accumulator || 0.0) + agent_result.cost }
      end
    end
  end
end
