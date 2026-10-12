# frozen_string_literal: true

require "json"
require "ruby_llm"

module Smith
  # A provider's refusal for want of credit or past a spending limit, whatever
  # status it came with. Smith takes each as RubyLLM::PaymentRequiredError,
  # the error RubyLLM raises for a 402 (its cause the error RubyLLM raised),
  # so the refusal is the provider account's (another provider in the
  # fallback chain is tried) and a host can name that one class in
  # interrupting_errors to have a step wait for credit instead of failing.
  #
  # A refusal is told by what the provider says it is, never by its status
  # alone: Anthropic's billing_error (402), its tier's monthly spend cap (429,
  # error_code enforced_spend_limit_reached), its spent credit and a spend
  # limit the account set (400s known only by how their message begins), and
  # OpenAI's insufficient_quota (429). A streamed request's refusal arrives
  # as a RubyLLM::ServerError, since RubyLLM takes every streamed error as a
  # 500. Any other error stays as it is: a rate limit that mentions a quota
  # (Gemini's) is a rate limit.
  module BillingRefusals
    CLASSES = [RubyLLM::BadRequestError, RubyLLM::RateLimitError, RubyLLM::ServerError].freeze
    TYPES = %w[billing_error insufficient_quota].freeze
    CODES = %w[enforced_spend_limit_reached].freeze
    MESSAGES = [
      /\AYour credit balance is too low/i,
      /\AYou have reached your specified (?:workspace )?API usage limits/i
    ].freeze
    private_constant :CLASSES, :TYPES, :CODES, :MESSAGES

    module_function

    # The error as Smith takes it: a billing refusal as a
    # RubyLLM::PaymentRequiredError, anything else unchanged.
    def classified(error)
      return error unless refusal?(error)

      begin
        raise RubyLLM::PaymentRequiredError.new(error.response, error.message), cause: error
      rescue RubyLLM::PaymentRequiredError => e
        e
      end
    end

    def refusal?(error)
      return false unless CLASSES.any? { error.is_a?(_1) }

      said = provider_error(error)
      details = said["details"].is_a?(Hash) ? said["details"] : {}

      TYPES.include?(said["type"]) ||
        CODES.include?(details["error_code"]) ||
        MESSAGES.any? { error.message.to_s.match?(_1) }
    end

    # The provider's own error object in the response body, or {} when the
    # body carries none.
    def provider_error(error)
      body = error.response.respond_to?(:body) ? error.response.body : nil
      body = JSON.parse(body) if body.is_a?(String)
      said = body["error"] if body.is_a?(Hash)
      said.is_a?(Hash) ? said : {}
    rescue JSON::ParserError
      {}
    end
  end
end
