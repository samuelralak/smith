# frozen_string_literal: true

require "digest"
require "json"

require_relative "diagnostic_text"
require_relative "batch/message_shape"

module Smith
  # Batch mode (`execute Agent, mode: :batch`, and the same on `fan_out`): a
  # step's provider request is sent through the host's batch queue instead of
  # over the wire, and the step waits for its result. Smith renders exactly
  # the request a synchronous call would post, hands it to
  # `Smith.config.batch_queue.enqueue(custom_id:, await_token:, request:,
  # execution_key:)` and waits on `:batch_result`; the host submits batches
  # (Smith::Providers::Anthropic::Batches), collects their results, and
  # resumes the run with every result of its wait. Smith never submits or
  # polls, and waits for the results without sleeping (an in-process
  # `retry_on` backoff sleeps as on any step; `durable: true` waits instead).
  module Batch
    EVENT = "batch_result"
    RESULT_TYPES = %w[succeeded errored canceled expired].freeze
    MISSING = "missing"
    MAX_REQUEST_BYTES = 32 * 1024 * 1024
    MAX_RESULTS_BYTES = 64 * 1024 * 1024
    INVALID_REQUEST = "invalid_request_error"
    CREDENTIAL_HEADERS = %w[authorization x-api-key x-goog-api-key].freeze

    module_function

    # The request a batch carries for one call: the provider, the payload it
    # would post, and the call's own headers (never credentials: the
    # connection's stay in it, and a call's own are refused), JSON-shaped,
    # bounded and frozen.
    def request(provider:, params:, headers:)
      if headers.to_h.keys.any? { CREDENTIAL_HEADERS.include?(_1.to_s.downcase) }
        raise WorkflowError, "a batch request cannot carry credentials in its headers"
      end

      encoded = JSON.generate("provider" => provider.to_s, "params" => params, "headers" => headers.to_h)
      if encoded.bytesize > MAX_REQUEST_BYTES
        raise WorkflowError, "a batch request is #{encoded.bytesize} bytes, past the #{MAX_REQUEST_BYTES} Smith sends"
      end

      deep_freeze(JSON.parse(encoded))
    end

    # What identifies a request's content: a SHA-256 of its payload and
    # headers as JSON gives them, so the request a delivery answers can be
    # told from one the step would render now.
    def digest(request) = digest_of(request.fetch("params"), request.fetch("headers"))

    # Whether a call renders a request other than the one sent (`digest`).
    # Nothing is sent, so nothing in it is refused; one JSON cannot give
    # counts as changed.
    def changed?(digest, params, headers)
      digest_of(params, headers.to_h) != digest
    rescue JSON::GeneratorError, JSON::NestingError, Encoding::UndefinedConversionError
      true
    end

    def digest_of(params, headers) = Digest::SHA256.hexdigest(JSON.generate([params, headers]))

    # A step's request id: its wait token, and for a fan-out branch a key of
    # the token and the branch (64 hex characters, a valid custom_id).
    def custom_id(token, branch_key = nil)
      branch_key.nil? ? token : Digest::SHA256.hexdigest("#{token}/#{branch_key}")
    end

    # The delivered results, checked: one per expected id, each a result of
    # a known type, keys as JSON gives them. Raises ArgumentError otherwise.
    def results!(payload, expected_ids)
      results = stringified(payload)
      unless results.keys.sort == expected_ids.sort
        raise ArgumentError, "a batch delivery must hold exactly the results of its #{expected_ids.length} requests"
      end

      results.each_value { |result| check_result!(result) }
      deep_freeze(results)
    end

    # The message of a succeeded result, or the error a failed one raises:
    # BatchRequestInvalid for a request the provider refused, else
    # BatchResultFailed (retryable).
    def message!(result)
      case result.fetch("type")
      when "succeeded" then result.fetch("message")
      when "errored" then raise_errored!(result)
      else raise BatchResultFailed.new(kind: result.fetch("type"))
      end
    end

    def raise_errored!(result)
      error = result["error"]
      type = error.dig("error", "type") || error["type"] if error.is_a?(Hash)
      raise BatchRequestInvalid if type == INVALID_REQUEST

      raise BatchResultFailed.new(kind: "errored", error_type: type.is_a?(String) ? type : nil)
    end

    def check_result!(result)
      raise ArgumentError, "a batch result must be a Hash with a type" unless result.is_a?(Hash)

      type = result["type"]
      raise ArgumentError, "a batch result's type must be one of #{RESULT_TYPES.join(", ")}" unless
        RESULT_TYPES.include?(type) || type == MISSING
      return unless type == "succeeded" && !MessageShape.valid?(result["message"])

      raise ArgumentError, "a succeeded batch result must carry a message of the provider's reply shape"
    end

    def stringified(payload)
      raise ArgumentError, "a batch delivery must be a Hash of request ids to results" unless payload.is_a?(Hash)

      encoded = JSON.generate(payload)
      raise ArgumentError, "a batch delivery is past #{MAX_RESULTS_BYTES} bytes" if encoded.bytesize > MAX_RESULTS_BYTES

      JSON.parse(encoded)
    rescue JSON::GeneratorError, JSON::NestingError, Encoding::UndefinedConversionError
      raise ArgumentError, "a batch delivery must be JSON-shaped"
    end

    def deep_freeze(value)
      case value
      when Hash then value.each_value { deep_freeze(_1) }.freeze
      when Array then value.each { deep_freeze(_1) }.freeze
      else value.freeze
      end
    end

    # The results a resumed step takes, one per branch (nil for a step
    # without branches), each with the digest of the request it answers, and
    # what a result does when its call renders another request
    # (`on_change`). Each is taken once: a follow-up call the step makes
    # after it (a repair) goes over the wire. `untaken` is what no call took
    # (a branch cancelled by a sibling's failure) or set aside (a result its
    # call would not use), paid for all the same.
    class Delivery
      Entry = Struct.new(:result, :digest)

      attr_reader :on_change

      def initialize(entries_by_branch, on_change: :keep)
        @entries = entries_by_branch.dup
        @set_aside = {}
        @on_change = on_change
        @lock = Mutex.new
      end

      def take(branch_key) = @lock.synchronize { @entries.delete(branch_key) }

      def for?(branch_key) = @lock.synchronize { @entries.key?(branch_key) }

      def set_aside(branch_key, entry) = @lock.synchronize { @set_aside[branch_key] = entry }

      def untaken
        @lock.synchronize do
          @set_aside.merge(@entries).tap do
            @entries.clear
            @set_aside.clear
          end
        end
      end
    end
  end
end
