# frozen_string_literal: true

module Smith
  class Agent
    module ProviderFailureHandling
      TRANSIENT_ERRORS = [
        RubyLLM::ServerError,
        RubyLLM::ServiceUnavailableError,
        RubyLLM::OverloadedError,
        RubyLLM::RateLimitError
      ].freeze
      MODEL_UNAVAILABLE_STATUSES = [404, 410].freeze
      PROVIDER_ACCOUNT_ERRORS = [
        RubyLLM::UnauthorizedError,
        RubyLLM::PaymentRequiredError
      ].freeze
      MODEL_PERMISSION_ERRORS = [RubyLLM::ForbiddenError].freeze

      private_constant :TRANSIENT_ERRORS, :MODEL_UNAVAILABLE_STATUSES,
                       :PROVIDER_ACCOUNT_ERRORS, :MODEL_PERMISSION_ERRORS

      private

      # A request whose outcome is uncertain is never sent again, to this
      # model or another.
      def handle_provider_failure!(error, model_reference, agent_class, fallback_available:, attempt_id: nil)
        account_failed_attempt(error, model_reference, agent_class, attempt_id:)
        raise error if error.is_a?(Smith::RequestOutcomeUncertain)

        if uncertain_tool_calls?
          raise Smith::ToolOutcomeUncertain.new(
            "provider failed after tool execution began; retry or fallback could replay an uncertain outcome"
          ), cause: error
        end
        return if ProviderFailureHandling.goes_again?(self, error, agent_class) && fallback_available

        raise terminal_provider_error(error, model_reference, agent_class), cause: error
      end

      def provider_failure?(error)
        error.is_a?(RubyLLM::Error) || error.is_a?(Smith::RequestOutcomeUncertain) ||
          (defined?(RubyLLM::ModelNotFoundError) && error.is_a?(RubyLLM::ModelNotFoundError)) ||
          error.is_a?(Faraday::TimeoutError) ||
          error.is_a?(Faraday::ConnectionFailed)
      end

      def provider_account_failure?(error)
        PROVIDER_ACCOUNT_ERRORS.any? { |error_class| error.is_a?(error_class) }
      end

      # A model the chain reaches whose provider takes no such content
      # (ContentParts builds the content).
      def unsupported_content?(error) = error.is_a?(::RubyLLM::UnsupportedAttachmentError)

      # A tool that is not replay-safe has run in the step: a fallback would
      # run it again.
      def uncertain_tool_calls?
        Tool.current_tool_execution_tracker&.uncertain?
      end

      def fallback_eligible?(error)
        unsupported_content?(error) ||
          transient_failure?(error) ||
          transport_failure?(error) ||
          provider_account_failure?(error) ||
          model_permission_failure?(error) ||
          model_unavailable?(error)
      end

      def transient_failure?(error)
        TRANSIENT_ERRORS.any? { |error_class| error.is_a?(error_class) }
      end

      def transport_failure?(error)
        error.is_a?(Faraday::TimeoutError) || error.is_a?(Faraday::ConnectionFailed)
      end

      def model_permission_failure?(error)
        MODEL_PERMISSION_ERRORS.any? { |error_class| error.is_a?(error_class) }
      end

      def model_unavailable?(error)
        return true if defined?(RubyLLM::ModelNotFoundError) && error.is_a?(RubyLLM::ModelNotFoundError)
        return false unless error.respond_to?(:response)

        response = error.response
        response.respond_to?(:status) && MODEL_UNAVAILABLE_STATUSES.include?(response.status.to_i)
      rescue StandardError
        false
      end

      def terminal_provider_error(error, model_reference, agent_class = nil)
        return Smith::AgentError.new(error.message) if ProviderFailureHandling.step_may_retry?(self, error, agent_class)
        if unsupported_content?(error)
          return Smith::ContentUnavailable.new("#{model_reference} takes none of this content: #{error.message}")
        end

        # A refused key, credit or model in a credentialed run reads as Smith's own words.
        refused = @smith_run_credentials&.refusal(error, model_reference)
        return refused if refused

        Smith::ProviderPermanentFailure.new(
          error.message,
          provider: model_reference.provider,
          model_id: model_reference.model_id,
          source_error_class: error.class.name
        )
      end

      # Called on the module, so a workflow including it gains none of these
      # names. Each reads the predicates above on `handler`, the workflow,
      # where a host may have defined its own.
      class << self
        # An image's request goes again, to another model or the step's
        # retry, only after a throttle or a refusal of the account, the
        # model or the content: a server's error may have done and billed
        # the work.
        def goes_again?(handler, error, agent_class)
          return handler.__send__(:fallback_eligible?, error) unless ImageRequest.declared(agent_class)

          throttled?(error) || handler.__send__(:provider_account_failure?, error) ||
            handler.__send__(:model_permission_failure?, error) || handler.__send__(:model_unavailable?, error) ||
            handler.__send__(:unsupported_content?, error)
        end

        # A provider that struggled leaves the step its retries, but for an
        # image's request only a throttle does (`goes_again?`).
        def step_may_retry?(handler, error, agent_class)
          (handler.__send__(:transient_failure?, error) || handler.__send__(:transport_failure?, error)) &&
            (!ImageRequest.declared(agent_class) || throttled?(error))
        end

        private

        def throttled?(error) = error.is_a?(RubyLLM::RateLimitError)
      end
    end
  end
end
