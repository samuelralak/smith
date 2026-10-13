# frozen_string_literal: true

require "json"
require "ruby_llm"

module Smith
  # An error of a streamed request as the provider said it was. RubyLLM
  # builds a streamed request's error response itself, its status a guess
  # from the error event's type (Anthropic's adapter says 500 unless
  # overloaded, OpenAI's 400 unless a server error or a rate limit), so a
  # wrong key, a model the provider does not serve or a refusal by region
  # could look like a passing outage or a bad request. Smith reads the type
  # the provider gave in the body (Anthropic's `error.type`, OpenAI's
  # `error.code`, else its `error.type`) and, when it names another status,
  # raises what RubyLLM raises for that status (its own mapping, context
  # length included), with the provider's message, the response's headers
  # kept, its cause the error RubyLLM raised. An error from a response the
  # provider sent whole (its status the provider's own), or whose body
  # names nothing it knows, stays as it is.
  module ProviderErrors
    STATUSES = {
      "invalid_request_error" => 400,
      "authentication_error" => 401,
      "invalid_api_key" => 401,
      "billing_error" => 402,
      "permission_error" => 403,
      "unsupported_country_region_territory" => 403,
      "not_found_error" => 404,
      "model_not_found" => 404,
      "request_too_large" => 413,
      "rate_limit_error" => 429,
      "rate_limit_exceeded" => 429,
      "timeout_error" => 504
    }.freeze
    private_constant :STATUSES

    Response = Struct.new(:status, :body)
    Said = Struct.new(:message) do
      def parse_error(_response) = message
    end
    private_constant :Response, :Said

    module_function

    # The error as Smith takes it: a streamed request's error whose body
    # names another status as the error RubyLLM raises for that status,
    # anything else unchanged.
    def classified(error)
      return error unless error.is_a?(RubyLLM::Error) && streamed?(error)

      said = said_of(body_of(error))
      status = named_status(said)
      return error if status.nil? || status == error.response.status.to_i

      reclassify(error, with_status(error.response, status), said["message"])
    end

    def named_status(said) = said && (STATUSES[said["code"].to_s] || STATUSES[said["type"].to_s])

    # A response RubyLLM built for a streamed request's error, never one the
    # provider sent whole (a Faraday::Response).
    def streamed?(error)
      response = error.response
      response.respond_to?(:status) && response.respond_to?(:body) && !response.is_a?(Faraday::Response)
    end

    def reclassify(error, response, message)
      named = begin
        RubyLLM::ErrorMiddleware.parse_error(provider: Said.new(message.is_a?(String) ? message : nil), response:)
      rescue RubyLLM::Error => e
        e
      end
      return error unless named.is_a?(RubyLLM::Error)

      begin
        raise named.class.new(response, named.message), cause: error
      rescue RubyLLM::Error => e
        e
      end
    end

    def with_status(response, status)
      response.respond_to?(:merge) ? response.merge(status:) : Response.new(status, response.body)
    end

    def said_of(body)
      said = body.is_a?(Hash) ? body["error"] : nil
      said.is_a?(Hash) ? said : nil
    end

    def body_of(error)
      body = error.response.body
      body.is_a?(String) ? JSON.parse(body) : body
    rescue JSON::ParserError
      nil
    end
  end
end
