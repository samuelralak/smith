# frozen_string_literal: true

module Smith
  module Providers
    # Whether a request that failed in transport may have reached the provider
    # and been billed: its answer timed out once it was sent (Faraday's
    # TimeoutError, a read or write timeout, or a gateway's 504), or its
    # connection was lost mid-exchange (a reset, a broken pipe, an end of
    # file, or TLS failing, which on a live connection is how a drop arrives).
    # A connection that never opened, or refused, sent nothing.
    module RequestOutcome
      LOST = %w[Errno::ECONNRESET Errno::EPIPE EOFError].freeze
      EXCEPTION_CAUSE = Exception.instance_method(:cause)
      private_constant :LOST, :EXCEPTION_CAUSE

      module_function

      def uncertain?(error)
        return true if error.is_a?(Faraday::TimeoutError) || error.is_a?(Faraday::SSLError) || gateway_timeout?(error)
        return false unless error.is_a?(Faraday::ConnectionFailed)

        LOST.include?(transport_cause(error)&.class&.name)
      end

      def gateway_timeout?(error)
        error.is_a?(::RubyLLM::ServiceUnavailableError) && error.response.respond_to?(:status) &&
          error.response.status.to_i == 504
      end

      def transport_cause(error)
        cause = EXCEPTION_CAUSE.bind_call(error)
        cause ||= error.wrapped_exception if error.respond_to?(:wrapped_exception)
        cause if cause.is_a?(Exception)
      rescue StandardError
        nil
      end
    end
  end
end
