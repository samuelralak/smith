# frozen_string_literal: true

module Smith
  class Agent
    module Lifecycle
      WORKFLOW_CONTINUATION_MESSAGE =
        "Use the preceding assistant result as input and perform your assigned workflow step."
      private_constant :WORKFLOW_CONTINUATION_MESSAGE

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
        primary = if agent_class.respond_to?(:model_block) && agent_class.model_block
                    resolve_dynamic_model(agent_class)
                  else
                    agent_class.chat_kwargs[:model]
                  end
        fallbacks = agent_class.fallback_models || []
        [primary, *fallbacks].compact
      end

      # Evaluates a block-form `model` declaration with the workflow's
      # @context (Hash, defaults to {} when uninitialized). The block
      # must return a non-empty string model id; any other value
      # surfaces as Smith::AgentError so the workflow's failure handler
      # treats it as a step failure rather than a silent miss.
      def resolve_dynamic_model(agent_class)
        result = agent_class.model_block.call(@context || {})
        return result if result.is_a?(String) && !result.empty?

        raise Smith::AgentError,
              "model block for #{agent_class} must return a non-empty string; got #{result.inspect}"
      end

      def attempt_model(agent_class, prepared_input, model_id)
        chat = agent_class.chat(model: model_id, **bridge_workflow_inputs(agent_class))
        add_prepared_input(chat, prepared_input)
        chat = chat.with_schema(agent_class.output_schema) if agent_class.output_schema
        chat.complete
      end

      # Bridges declared agent `inputs` from the workflow's @context Hash
      # to the agent invocation kwargs, so block-form RubyLLM DSLs (tools,
      # instructions, params, headers, schema) can access workflow-context
      # data via bare method calls on `self` inside the block (RubyLLM
      # invokes these via `runtime.instance_exec(&block)`, exposing each
      # declared input as a singleton method on the runtime object).
      # Smith's own `model` block-form already receives @context directly
      # via `block.call(@context)`; this bridge gives runtime_context the
      # same surface for the RubyLLM-owned blocks.
      #
      # Bridges ONLY user-declared inputs — reserved names
      # (Smith::Agent::RESERVED_INPUT_NAMES: model_id, provider,
      # endpoint_mode) are auto-injected by Smith::Agent.chat from the
      # resolved profile, NOT from @context. The slice prevents the bridge
      # from accidentally passing through stale or wrong values that
      # happen to live in @context under those keys.
      #
      # Contract: declared inputs are ALWAYS passed (with nil when absent
      # from @context). The declaration is the contract — `inputs :form_kind`
      # promises that `form_kind` will be a callable singleton method on
      # the runtime regardless of whether @context happens to have a value.
      # This eliminates `respond_to?` defensiveness in agent blocks and
      # mirrors the silent-nil semantics agent authors get from `ctx[:k]`
      # in the model block. Non-Hash @context short-circuits.
      def bridge_workflow_inputs(agent_class)
        return {} unless @context.is_a?(Hash)

        declared = agent_class.inputs || []
        user_declared = declared - Smith::Agent::RESERVED_INPUT_NAMES
        user_declared.to_h do |name|
          [name, @context[name]]
        end
      end

      def add_prepared_input(chat, prepared_input)
        return unless prepared_input

        prepared_input = provider_safe_prepared_input(prepared_input)
        system_messages, other_messages = prepared_input.partition do |message|
          message_role(message) == :system
        end

        merge_system_messages!(chat, system_messages) if system_messages.any?
        other_messages.each { |message| chat.add_message(message) }
      end

      def provider_safe_prepared_input(prepared_input)
        messages = prepared_input.to_a
        return messages unless workflow_handoff?(messages)

        messages + [{ role: :user, content: WORKFLOW_CONTINUATION_MESSAGE }]
      end

      def workflow_handoff?(messages)
        message = messages.reverse_each.find { |candidate| message_role(candidate) != :system }
        return false unless message
        return false unless message_role(message) == :assistant
        return false unless defined?(@last_output) && !@last_output.nil?

        message_content(message) == @last_output
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
        unless combined_contents.all?(String)
          return prepared_system_messages.each { |message| chat.add_message(message) }
        end

        if chat.respond_to?(:with_instructions)
          chat.with_instructions(combined_contents.join("\n\n"))
        else
          prepared_system_messages.each { |message| chat.add_message(message) }
        end
      end

      def message_role(message)
        message_attribute(message, :role)&.to_sym
      end

      def message_content(message)
        message_attribute(message, :content)
      end

      def message_attribute(message, name)
        return message.public_send(name) if message.respond_to?(name)
        return message[name] if message.respond_to?(:key?) && message.key?(name)

        message[name.to_s]
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
        agent_result = Workflow::AgentResult.new(
          content: nil, input_tokens: input, output_tokens: output, cost: cost, model_used: model_id
        )
        Thread.current[:smith_failed_agent_results] ||= []
        Thread.current[:smith_failed_agent_results] << agent_result
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
          usage_id: SecureRandom.uuid,
          agent_name: agent_class.register_as,
          model: model_id,
          input_tokens: agent_result.input_tokens,
          output_tokens: agent_result.output_tokens,
          cost: agent_result.cost,
          attempt_kind: attempt_kind,
          recorded_at: Time.now.utc.iso8601
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
