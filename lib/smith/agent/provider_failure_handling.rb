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

      def handle_provider_failure!(error, model_reference, agent_class, fallback_available:, attempt_id: nil)
        account_failed_attempt(error, model_reference, agent_class, attempt_id:)
        if completed_tool_calls?
          raise Smith::ToolOutcomeUncertain.new(
            "provider failed after tool execution began; retry or fallback could replay an uncertain outcome"
          ), cause: error
        end
        return if fallback_eligible?(error) && fallback_available

        raise terminal_provider_error(error, model_reference), cause: error
      end

      def provider_failure?(error)
        error.is_a?(RubyLLM::Error) ||
          (defined?(RubyLLM::ModelNotFoundError) && error.is_a?(RubyLLM::ModelNotFoundError)) ||
          error.is_a?(Faraday::TimeoutError) ||
          error.is_a?(Faraday::ConnectionFailed)
      end

      def provider_account_failure?(error)
        PROVIDER_ACCOUNT_ERRORS.any? { |error_class| error.is_a?(error_class) }
      end

      def completed_tool_calls?
        Tool.current_tool_execution_tracker&.started?
      end

      def fallback_eligible?(error)
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

      def terminal_provider_error(error, model_reference)
        return Smith::AgentError.new(error.message) if transient_failure?(error) || transport_failure?(error)

        Smith::ProviderPermanentFailure.new(
          error.message,
          provider: model_reference.provider,
          model_id: model_reference.model_id,
          source_error_class: error.class.name
        )
      end
    end
  end
end
