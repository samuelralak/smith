# frozen_string_literal: true

module Smith
  class Agent
    module Lifecycle
      TRANSIENT_ERRORS = [
        RubyLLM::ServerError, RubyLLM::ServiceUnavailableError,
        RubyLLM::OverloadedError, RubyLLM::RateLimitError
      ].freeze

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
        models = build_model_chain(agent_class)
        @last_attempt_model = nil

        models.each_with_index do |model_id, index|
          check_deadline! if index.positive?
          @last_attempt_model = model_id
          return attempt_model(agent_class, prepared_input, model_id)
        rescue Smith::Error
          raise
        rescue StandardError => e
          account_failed_attempt(e, model_id)
          raise Smith::AgentError, e.message unless fallback_eligible?(e) && index < models.length - 1
        end
      end

      def build_model_chain(agent_class)
        primary = agent_class.chat_kwargs[:model]
        fallbacks = agent_class.fallback_models || []
        [primary, *fallbacks].compact
      end

      def attempt_model(agent_class, prepared_input, model_id)
        chat = agent_class.chat(model: model_id)
        prepared_input&.each { |msg| chat.add_message(msg) }
        chat = chat.with_schema(agent_class.output_schema) if agent_class.output_schema
        chat.complete
      end

      def fallback_eligible?(error)
        TRANSIENT_ERRORS.any? { |klass| error.is_a?(klass) } ||
          error.is_a?(Faraday::TimeoutError) ||
          error.is_a?(Faraday::ConnectionFailed)
      end

      def account_failed_attempt(error, model_id)
        return unless error.respond_to?(:input_tokens) && error.respond_to?(:output_tokens)

        input = error.input_tokens
        output = error.output_tokens
        return unless input.is_a?(Integer) && output.is_a?(Integer)

        cost = Smith::Pricing.compute_cost(model: model_id, input_tokens: input, output_tokens: output)
        accumulate_usage(Workflow::AgentResult.new(nil, input, output, cost, model_id))
      end

      def snapshot_and_finalize(agent_class, response)
        agent_result = Workflow::AgentResult.from_response(response, response&.content, model_used: @last_attempt_model)
        Thread.current[:smith_last_agent_result] = agent_result
        emit_token_usage(agent_result)
        compute_agent_cost(agent_result)
        accumulate_usage(agent_result)

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
          data: { input_tokens: agent_result.input_tokens, output_tokens: agent_result.output_tokens }
        )
      end

      def compute_agent_cost(agent_result)
        return unless agent_result.usage_known?

        model = agent_result.model_used
        agent_result.cost = Smith::Pricing.compute_cost(
          model: model, input_tokens: agent_result.input_tokens, output_tokens: agent_result.output_tokens
        )
      end

      def accumulate_usage(agent_result)
        if agent_result.usage_known?
          @usage_mutex ||= Mutex.new
          @usage_mutex.synchronize do
            @total_tokens = (@total_tokens || 0) + agent_result.input_tokens + agent_result.output_tokens
          end
        end

        return unless agent_result.cost

        @usage_mutex ||= Mutex.new
        @usage_mutex.synchronize { @total_cost = (@total_cost || 0.0) + agent_result.cost }
      end
    end
  end
end
