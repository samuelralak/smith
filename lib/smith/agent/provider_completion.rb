# frozen_string_literal: true

require_relative "provider_failure_handling"
require_relative "invocation_preparation"
require_relative "provider_attempt"
require_relative "provider_call_timing"
require_relative "provider_candidate_sequence"

module Smith
  class Agent
    module ProviderCompletion
      include ProviderFailureHandling
      include InvocationPreparation
      include ProviderCallTiming

      private

      def complete_with_provider(agent_class, prepared_input, output_schema:)
        candidates = ProviderCandidateSequence.new(build_model_chain(agent_class))
        candidates.each do |model_reference, index|
          check_deadline! if index.positive?
          attempt = attempt_model(agent_class, prepared_input, model_reference, output_schema:, attempt_index: index)
          return attempt if attempt.success?

          candidates.suppress(account_failed_provider(attempt, model_reference))
          handle_provider_failure!(
            attempt.error, attempt.model_reference, agent_class,
            fallback_available: candidates.fallback_available?,
            attempt_id: attempt.attempt_id
          )
        end

        # Fail closed: an empty candidate chain (agent without a model)
        # or any exhausted sequence must surface a typed diagnostic, not
        # the sequence itself destructured into nils.
        raise Smith::AgentError,
              "no executable model candidate for #{agent_class}; declare a model or fallback_models"
      end

      # Suppression keys on the provider that actually rejected the
      # account; when the chat is unobservable the attempted reference's
      # declared provider is the best available attribution, so a dead
      # account is not billed a second same-provider attempt.
      def account_failed_provider(attempt, attempted_reference)
        return unless provider_account_failure?(attempt.error)

        attempt.model_reference.provider || attempted_reference.provider
      end

      def build_model_chain(agent_class)
        references = [primary_model_reference(agent_class), *fallback_model_references(agent_class)].compact
        references.each_with_object([]) do |reference, chain|
          chain << reference unless chain.any? { |kept| kept.same_candidate?(reference) }
        end
      end

      def primary_model_reference(agent_class)
        return resolve_dynamic_model(agent_class) if agent_class.model_block

        model_id = agent_class.chat_kwargs[:model]
        return unless model_id

        # Static declarations stay literal: RubyLLM owns the meaning of
        # the declared id, so a slashed id ("openai/gpt-5") is not split
        # into provider/model here the way ModelReference.coerce parses
        # host-supplied strings.
        ModelReference.new(model_id: model_id, provider: agent_class.chat_kwargs[:provider])
      end

      def fallback_model_references(agent_class)
        Array(agent_class.fallback_models).map { |model| ModelReference.coerce(model) }
      end

      def resolve_dynamic_model(agent_class)
        result = agent_class.model_block.call(@context || {})
        reference = ModelReference.coerce(result)
        return reference if reference.provider

        raise Smith::AgentError,
              "model block for #{agent_class} must return a provider-qualified model reference; got #{result.inspect}"
      rescue ArgumentError, Dry::Struct::Error => e
        raise Smith::AgentError, "invalid model block result for #{agent_class}: #{e.message}"
      end

      # rubocop:disable Metrics/AbcSize -- one provider attempt is a single
      # cohesive lifecycle (identity, prepared chat, observed model, timed
      # completion, prefix accounting on failure); splitting it would scatter
      # the rescue-path accounting away from what it accounts for.
      def attempt_model(agent_class, prepared_input, model_reference, output_schema:, attempt_index:)
        attempt_id = SecureRandom.uuid
        chat = prepared_attempt_chat(agent_class, prepared_input, model_reference, output_schema:)
        message_count = chat_message_count(chat)
        observed_reference = observed_model_reference(chat, fallback: model_reference)
        timer = ProviderCallTiming::Timer.start
        response = chat.complete
        timer.stop
        completion = Completion.from_messages(response: response, messages: new_chat_messages(chat, message_count))

        attempt = ProviderAttempt.success(
          completion:, model_reference: observed_reference, attempt_id:, duration_ms: timer.elapsed_ms
        )
        record_provider_call_trace(attempt, attempt_index)
        attempt
      rescue StandardError => e
        timer&.stop
        observed_reference ||= observed_model_reference(chat, fallback: model_reference)
        account_completed_prefix(agent_class, observed_reference, new_chat_messages(chat, message_count), attempt_id:)
        attempt = failed_provider_attempt(e, observed_reference, attempt_id, timer, attempt_index)
        raise unless provider_failure?(e)

        attempt
      end
      # rubocop:enable Metrics/AbcSize

      def observed_model_reference(chat, fallback:)
        model = observable_model(chat)
        return fallback unless model.respond_to?(:id) && !model.id.to_s.empty?

        ModelReference.coerce(model.id, provider: observed_provider(model, fallback))
      rescue StandardError
        fallback
      end

      def observable_model(chat)
        resolved_chat = chat.respond_to?(:to_llm) ? chat.to_llm : chat
        resolved_chat.model if resolved_chat.respond_to?(:model)
      end

      def observed_provider(model, fallback)
        model.respond_to?(:provider) && !model.provider.to_s.empty? ? model.provider : fallback.provider
      end

      def prepared_attempt_chat(agent_class, prepared_input, model_reference, output_schema:)
        chat = agent_class.chat(**model_reference.chat_options, **bridge_workflow_inputs(agent_class))
        add_prepared_input(chat, prepared_input)
        output_schema ? chat.with_schema(output_schema) : chat
      end

      def chat_message_count(chat)
        chat.respond_to?(:messages) ? chat.messages.length : nil
      end

      def new_chat_messages(chat, message_count)
        message_count ? chat.messages.drop(message_count) : []
      end
    end
  end
end
