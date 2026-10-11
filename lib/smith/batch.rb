# frozen_string_literal: true

require "digest"
require "json"

module Smith
  # Batch mode (`execute Agent, mode: :batch`, and the same on `fan_out`): a
  # step's provider request is sent through the host's batch queue instead of
  # over the wire, and the step waits for its result. Smith renders exactly
  # the request a synchronous call would post, hands it to
  # `Smith.config.batch_queue.enqueue(custom_id:, await_token:, request:,
  # execution_key:)` and waits on `:batch_result`; the host submits batches
  # (Smith::Providers::Anthropic::Batches), collects their results, and
  # resumes the run with every result of its wait. Smith never submits,
  # polls or sleeps.
  module Batch
    EVENT = "batch_result"
    RESULT_TYPES = %w[succeeded errored canceled expired].freeze
    MISSING = "missing"
    MAX_REQUEST_BYTES = 32 * 1024 * 1024
    MAX_RESULTS_BYTES = 64 * 1024 * 1024
    INVALID_REQUEST = "invalid_request_error"

    module_function

    # The request a batch carries for one call: the provider, the payload it
    # would post, and the call's own headers (never the connection's
    # credentials), JSON-shaped, bounded and frozen.
    def request(provider:, params:, headers:)
      encoded = JSON.generate("provider" => provider.to_s, "params" => params, "headers" => headers.to_h)
      if encoded.bytesize > MAX_REQUEST_BYTES
        raise WorkflowError, "a batch request is #{encoded.bytesize} bytes, past the #{MAX_REQUEST_BYTES} Smith sends"
      end

      deep_freeze(JSON.parse(encoded))
    end

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

      raise BatchResultFailed.new(kind: "errored", error_type: type)
    end

    def check_result!(result)
      raise ArgumentError, "a batch result must be a Hash with a type" unless result.is_a?(Hash)

      type = result["type"]
      raise ArgumentError, "a batch result's type must be one of #{RESULT_TYPES.join(", ")}" unless
        RESULT_TYPES.include?(type) || type == MISSING
      return unless type == "succeeded" && !result["message"].is_a?(Hash)

      raise ArgumentError, "a succeeded batch result must carry its message"
    end

    def stringified(payload)
      raise ArgumentError, "a batch delivery must be a Hash of request ids to results" unless payload.is_a?(Hash)

      encoded = JSON.generate(payload)
      raise ArgumentError, "a batch delivery is past #{MAX_RESULTS_BYTES} bytes" if encoded.bytesize > MAX_RESULTS_BYTES

      JSON.parse(encoded)
    rescue JSON::GeneratorError, Encoding::UndefinedConversionError
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
    # without branches). Each is taken once: a follow-up call the step makes
    # after it (a repair) goes over the wire.
    class Delivery
      def initialize(results_by_branch)
        @results = results_by_branch.dup
        @lock = Mutex.new
      end

      def take(branch_key) = @lock.synchronize { @results.delete(branch_key) }

      def for?(branch_key) = @lock.synchronize { @results.key?(branch_key) }
    end
  end
end
