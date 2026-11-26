# frozen_string_literal: true

require_relative "../../canonical_json"
require_relative "../../diagnostic_text"
require_relative "../../pricing"

module Smith
  module Evals
    class Recorder
      # A step record's fields read from one observation (the trial schema's
      # $defs/step), as plain JSON. Its cost is the sum of its responses',
      # each priced alone with Smith::Pricing.compute_cost, as its usage
      # entry is (so a tiered price picks its tier per response, as the
      # provider bills and the budget ledger settles), in integer nanos
      # rounded half to even once; unknown when any response's price is.
      # With no tokens it is 0 when nothing was sent (a skip, a refusal
      # before the call) or the provider refused it (not billed), and
      # unknown when an aborted or answered call reported none. Its settings
      # keep each value the schema takes, null otherwise. A failure's message
      # is the seam's: for the four key and account failures Smith's fixed
      # text (AttemptObservation::FIXED_MESSAGES, the one place it is
      # written), whatever the provider said. Internal. O(R) for R responses
      # but the bounded strings.
      module Fields
        TOKENS = { "input" => :input, "output" => :output, "cache_read" => :cache_read,
                   "cache_write" => :cache_write, "thinking" => :thinking }.freeze
        PRICED = { input_tokens: :input, output_tokens: :output, cache_read_tokens: :cache_read,
                   cache_write_tokens: :cache_write, image_input_tokens: :image_input,
                   image_output_tokens: :image_output }.freeze
        NANOS = 1_000_000_000
        MAX_NAMES = 1_024
        MAX_EFFORT = 64

        module_function

        # Every field but the step's messages and cut, in the record's order:
        # those before the messages, and those after them.
        def of(attempt, seq, offset_ms)
          names = tool_call_names(attempt)
          [{ "seq" => seq, **identity(attempt), **call(attempt, offset_ms), **spend(attempt),
             "stop_reason" => bounded(attempt.stop_reason, 64), "sent_count" => attempt.sent_count.to_i },
           { "tool_calls" => names.length, "tool_call_names" => names }]
        end

        def identity(attempt)
          { "position" => position(attempt.position), "agent" => bounded(attempt.agent, 256).to_s,
            "components" => components(attempt.components), "attempt_id" => bounded(attempt.attempt_id, 64).to_s,
            "attempt_index" => attempt.attempt_index.to_i }
        end

        def call(attempt, offset_ms)
          { "outcome" => attempt.outcome.to_s, "failure" => failure(attempt.failure), "model" => attempt.model&.to_s,
            "provider" => attempt.provider&.to_s, "settings" => settings(attempt.settings),
            "mode" => attempt.mode.to_s, "memo" => attempt.memo == true, "offset_ms" => offset_ms,
            "duration_ms" => attempt.duration_ms }
        end

        def spend(attempt)
          cost, known = priced(attempt)
          { "tokens" => tokens(attempt.tokens), "cost_nanos" => cost, "cost_known" => known }
        end

        def position(place)
          place ||= {}
          key = place[:branch_key]
          { "workflow" => place[:workflow]&.to_s, "transition" => place[:transition]&.to_s,
            "branch_key" => key.is_a?(Integer) ? key : key&.to_s, "round" => place[:round],
            "execution_key" => place[:execution_key]&.to_s }.freeze
        end

        def components(list)
          list&.map { { "id" => _1[:id].to_s, "version" => _1[:version].to_s }.freeze }&.freeze
        end

        def failure(failure)
          return if failure.nil?

          { "kind" => failure[:kind].to_s, "error_class" => bounded(failure[:error_class], 512).to_s,
            "message" => bounded(failure[:message], 1_024).to_s }.freeze
        end

        # A request's params may carry anything: a value the schema would
        # refuse is null.
        def settings(sent)
          temperature, limit, thinking = (sent || {}).values_at(:temperature, :max_output_tokens, :thinking)
          { "temperature" => temperature(temperature), "max_output_tokens" => count_of(limit),
            "thinking" => thinking(thinking) }.freeze
        end

        def temperature(value)
          return value if value.is_a?(Float) && value.finite? && !value.negative?

          value if value.is_a?(Integer) && value.between?(0, CanonicalJSON::MAX_SAFE_INTEGER)
        end

        def thinking(sent)
          return unless sent.is_a?(Hash)

          effort = sent[:effort]
          effort = effort.to_s if effort.is_a?(Symbol)
          effort = nil unless effort.is_a?(String) && effort.valid_encoding? && effort.length <= MAX_EFFORT
          kept = { "effort" => effort, "budget" => count_of(sent[:budget]) }.compact
          kept.freeze unless kept.empty?
        end

        # What JSON holds exactly (CanonicalJSON's integers).
        def count_of(value) = value.is_a?(Integer) && value.between?(1, CanonicalJSON::MAX_SAFE_INTEGER) ? value : nil

        def tokens(tokens) = tokens && TOKENS.transform_values { count(tokens[_1]) }.freeze

        def priced(attempt)
          responses = Array(attempt.responses)
          return none_reported(attempt) if responses.empty?

          costs = responses.map { response_cost(attempt, _1) }
          costs.all? ? [(costs.sum * NANOS).round(half: :even).to_i, true] : [nil, false]
        end

        # One response's cost, exact (a Float price as its decimal reads).
        def response_cost(attempt, response)
          tokens = response[:tokens] || {}
          cost = Pricing.compute_cost(model: attempt.model.to_s, provider: attempt.provider,
                                      mode: response[:mode] || :sync, **PRICED.transform_values { count(tokens[_1]) })
          return if cost.nil?

          cost.is_a?(Float) ? Rational(cost.to_s) : cost.to_r
        end

        def none_reported(attempt)
          sent_nothing = attempt.outcome == :skipped || attempt.duration_ms.nil? || attempt.outcome == :failed
          sent_nothing ? [0, true] : [nil, false]
        end

        def tool_call_names(attempt)
          Array(attempt.tool_call_names).first(MAX_NAMES).map { bounded(_1, 128).to_s }.freeze
        end

        def count(value) = value.is_a?(Integer) && value.positive? ? value : 0

        def bounded(value, bytes) = value.nil? ? nil : DiagnosticText.capture(value.to_s, max_bytes: bytes)
      end
    end
  end
end
