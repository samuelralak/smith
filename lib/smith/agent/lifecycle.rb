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
        response, model_used = complete_with_provider(agent_class, prepared_input)
        snapshot_and_finalize(agent_class, response, model_used)
      end

      # Returns [response, model_used] as local data — no shared mutable
      # state. Previously this method set `@last_attempt_model` on the
      # workflow instance and `snapshot_and_finalize` read it back; under
      # parallel fan-out, two branches sharing the workflow could race
      # and attribute the wrong model to the wrong response. Local data
      # eliminates the race entirely.
      def complete_with_provider(agent_class, prepared_input)
        models = build_model_chain(agent_class)

        models.each_with_index do |model_id, index|
          check_deadline! if index.positive?
          response = attempt_model(agent_class, prepared_input, model_id)
          return [response, model_id]
        rescue Smith::Error
          raise
        rescue StandardError => e
          account_failed_attempt(e, model_id, agent_class)
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
        add_prepared_input(chat, prepared_input)
        chat = chat.with_schema(agent_class.output_schema) if agent_class.output_schema
        chat.complete
      end

      def add_prepared_input(chat, prepared_input)
        return unless prepared_input

        system_messages, other_messages = prepared_input.partition do |message|
          message_role(message) == :system
        end

        merge_system_messages!(chat, system_messages) if system_messages.any?
        other_messages.each { |message| chat.add_message(message) }
      end

      def merge_system_messages!(chat, prepared_system_messages)
        return prepared_system_messages.each { |message| chat.add_message(message) } unless chat.respond_to?(:messages)

        existing_system_contents = chat.messages.filter_map do |message|
          message.content if message_role(message) == :system
        end
        prepared_system_contents = prepared_system_messages.filter_map do |message|
          message_content(message)
        end

        combined_contents = existing_system_contents + prepared_system_contents
        return if combined_contents.empty?
        return prepared_system_messages.each { |message| chat.add_message(message) } unless combined_contents.all?(String)

        if chat.respond_to?(:with_instructions)
          chat.with_instructions(combined_contents.join("\n\n"))
        else
          prepared_system_messages.each { |message| chat.add_message(message) }
        end
      end

      def message_role(message)
        if message.respond_to?(:role)
          message.role&.to_sym
        else
          message[:role]&.to_sym
        end
      end

      def message_content(message)
        if message.respond_to?(:content)
          message.content
        else
          message[:content]
        end
      end

      def fallback_eligible?(error)
        TRANSIENT_ERRORS.any? { |klass| error.is_a?(klass) } ||
          error.is_a?(Faraday::TimeoutError) ||
          error.is_a?(Faraday::ConnectionFailed)
      end

      # `agent_class` is now a parameter (was previously implicit via
      # `@last_attempt_model`-only path). The caller (`complete_with_provider`)
      # has the local already, so no shared mutable state is needed.
      # Records the failed attempt's tokens via the unified `record_usage`
      # helper, marking the entry as `:failed_attempt`.
      def account_failed_attempt(error, model_id, agent_class)
        return unless error.respond_to?(:input_tokens) && error.respond_to?(:output_tokens)

        input = error.input_tokens
        output = error.output_tokens
        return unless input.is_a?(Integer) && output.is_a?(Integer)

        cost = Smith::Pricing.compute_cost(model: model_id, input_tokens: input, output_tokens: output)
        agent_result = Workflow::AgentResult.new(nil, input, output, cost, model_id)
        record_usage(agent_class, agent_result, :failed_attempt, model_id)
      end

      def snapshot_and_finalize(agent_class, response, model_used)
        agent_result = Workflow::AgentResult.from_response(response, response&.content, model_used: model_used)
        Thread.current[:smith_last_agent_result] = agent_result
        emit_token_usage(agent_result)
        compute_agent_cost(agent_result)
        record_usage(agent_class, agent_result, :completed_attempt, agent_result.model_used)

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

      # Single critical section: all three of `@total_tokens`,
      # `@total_cost`, and `@usage_entries` update under one mutex
      # acquisition. Replaces the prior `accumulate_usage` which took
      # the mutex twice (once for tokens, once for cost) — under
      # parallel fan-out two branches could interleave between those
      # blocks, leaving totals momentarily inconsistent. Adding the
      # entry append in a third pass would have widened the window;
      # one pass closes it entirely.
      #
      # `@usage_mutex` is eagerly initialized in `Workflow#initialize`
      # AND `Workflow#restore_state` (since `from_state` allocates
      # without `initialize`), so it's always present here.
      def record_usage(agent_class, agent_result, attempt_kind, model_id)
        return unless agent_result.usage_known?

        entry = Workflow::UsageEntry.new(
          SecureRandom.uuid,
          agent_class.register_as,
          model_id,
          agent_result.input_tokens,
          agent_result.output_tokens,
          agent_result.cost,
          attempt_kind,
          Time.now.utc.iso8601
        )

        @usage_mutex.synchronize do
          @total_tokens = (@total_tokens || 0) + agent_result.input_tokens + agent_result.output_tokens
          @total_cost   = (@total_cost   || 0.0) + (agent_result.cost || 0.0)
          @usage_entries << entry
        end
      end
    end
  end
end
