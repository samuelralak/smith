# frozen_string_literal: true

require_relative "../../types"
require_relative "../../budget/decimal_context"
require_relative "../message_value_normalizer"
require_relative "../prepared_step"
require_relative "../usage_entry"
require_relative "payload"

module Smith
  class Workflow
    module Composite
      # Length is fail-closed value validation, not logic: every key the
      # contract admits gets a bounded value check beside the contract that
      # admits it. Splitting the checks away from the payload they guard
      # would trade cohesion for a metric.
      class Effects < Payload # rubocop:disable Metrics/ClassLength
        attr_reader :total_tokens, :total_cost

        # Required keys are the pre-attribution UsageEntry shape, so effects
        # produced by an older Smith (a mid-deploy branch worker or a
        # restored checkpoint) stay valid; allowed keys are the current
        # member set, so unknown keys still reject. The attribution members
        # (transition, branch_key, round, attempt_id) are optional by
        # construction.
        USAGE_ALLOWED_ATTRIBUTES = Workflow::UsageEntry.members.map(&:to_s).freeze
        USAGE_REQUIRED_ATTRIBUTES =
          (USAGE_ALLOWED_ATTRIBUTES - %w[transition branch_key round attempt_id workflow]).freeze
        TOOL_REQUIRED_ATTRIBUTES = %w[tool captured].freeze
        TOOL_ALLOWED_ATTRIBUTES = (TOOL_REQUIRED_ATTRIBUTES + %w[tool_call_id]).freeze
        private_constant :USAGE_ALLOWED_ATTRIBUTES, :USAGE_REQUIRED_ATTRIBUTES,
                         :TOOL_REQUIRED_ATTRIBUTES, :TOOL_ALLOWED_ATTRIBUTES

        attribute :usage_entries, Types::Array
        attribute :tool_results, Types::Array
        attribute :budget_consumed, Types::Hash

        def initialize(attributes)
          owned = self.class.normalize_attributes(attributes)
          normalized = MessageValueNormalizer.new(owned, label: "composite effects").call
          usage_entries, tool_results, budget_consumed =
            normalized.values_at("usage_entries", "tool_results", "budget_consumed")
          @total_tokens, @total_cost = validate_usage_entries!(usage_entries)
          validate_tool_results!(tool_results)
          validate_budget!(budget_consumed)
          super(usage_entries:, tool_results:, budget_consumed:)
        end

        private

        def validate_usage_entries!(entries)
          raise ArgumentError, "composite usage entries must be an Array" unless entries.is_a?(Array)

          entries.each do |entry|
            validate_bounded_keys!(entry, USAGE_REQUIRED_ATTRIBUTES, USAGE_ALLOWED_ATTRIBUTES, "composite usage entry")
            validate_usage_identity!(entry)
            validate_usage_attribution!(entry)
            validate_usage_amount!(entry.fetch("input_tokens"), "input_tokens")
            validate_usage_amount!(entry.fetch("output_tokens"), "output_tokens")
            validate_cost!(entry.fetch("cost"))
          end
          usage_totals(entries)
        end

        def usage_totals(entries)
          tokens = entries.sum { _1.fetch("input_tokens") + _1.fetch("output_tokens") }
          if tokens > PreparedStep::MAX_COUNTER_VALUE
            raise ArgumentError, "composite usage token total exceeds the signed 64-bit limit"
          end

          cost = Budget::DecimalContext.call do
            entries.sum(BigDecimal("0")) { BigDecimal((_1.fetch("cost") || 0).to_s) }
          end.to_f
          raise ArgumentError, "composite usage cost total must be finite" unless cost.finite?

          [tokens, cost]
        end

        def validate_usage_identity!(entry)
          validate_uuid!(entry.fetch("usage_id"), "composite usage entry usage_id")
          # agent_name and provider are nil-allowed; any other value
          # (false included) must be a non-empty String.
          %w[agent_name provider].each do |key|
            value = entry.fetch(key)
            validate_nonempty_string!(value, "composite usage entry #{key}") unless value.nil?
          end
          %w[model attempt_kind recorded_at].each do |key|
            validate_nonempty_string!(entry.fetch(key), "composite usage entry #{key}")
          end
        end

        # The optional attribution keys are bounded values, not just bounded
        # keys: a present key with a wrong-typed, empty, or oversized value
        # rejects exactly like the identity fields do. Absent keys (older
        # producers, or nil-omitting serialization) stay valid.
        def validate_usage_attribution!(entry)
          %w[transition branch_key workflow].each do |key|
            validate_bounded_string!(entry.fetch(key), "composite usage entry #{key}", 256) if entry.key?(key)
          end
          validate_usage_amount!(entry.fetch("round"), "round") if entry.key?("round")
          validate_uuid!(entry.fetch("attempt_id"), "composite usage entry attempt_id") if entry.key?("attempt_id")
        end

        def validate_uuid!(value, label)
          return if value.is_a?(String) && PreparedStep::UUID_PATTERN.match?(value)

          raise ArgumentError, "#{label} must be a UUID"
        end

        def validate_bounded_string!(value, label, max_length)
          return if value.is_a?(String) && value.length.between?(1, max_length)

          raise ArgumentError, "#{label} must be a bounded non-empty String"
        end

        def validate_nonempty_string!(value, label)
          return if value.is_a?(String) && !value.empty?

          raise ArgumentError, "#{label} must be a non-empty String"
        end

        def validate_usage_amount!(amount, name)
          return if amount.is_a?(Integer) && amount >= 0

          raise ArgumentError, "composite usage entry #{name} must be a non-negative Integer"
        end

        def validate_cost!(cost)
          return if cost.nil? || (cost.is_a?(Numeric) && cost.finite? && cost >= 0)

          raise ArgumentError, "composite usage entry cost must be a finite non-negative number or nil"
        end

        def validate_tool_results!(entries)
          raise ArgumentError, "composite tool results must be an Array" unless entries.is_a?(Array)

          entries.each do |entry|
            validate_bounded_keys!(entry, TOOL_REQUIRED_ATTRIBUTES, TOOL_ALLOWED_ATTRIBUTES, "composite tool result")
            validate_bounded_string!(entry.fetch("tool"), "composite tool result tool", 256)

            # Present only for provider-batch invocations; the producer never
            # writes a nil, so a present key must carry a real id. Provider
            # tool-call ids are short strings; 1024 is far above any observed
            # provider format while still bounding the payload.
            if entry.key?("tool_call_id")
              validate_bounded_string!(entry.fetch("tool_call_id"), "composite tool result tool_call_id", 1024)
            end
          end
        end

        def validate_budget!(budget)
          raise ArgumentError, "composite budget consumption must be a Hash" unless budget.is_a?(Hash)

          budget.each do |dimension, amount|
            unless !dimension.empty? && amount.is_a?(Numeric) && amount.finite? && amount >= 0
              raise ArgumentError, "composite budget consumption is invalid"
            end
          end
        end

        # Every required key present, no key outside the allowed set: older
        # producers (missing optional keys) pass, unknown keys still reject.
        # Passing the same set for both is an exact-keys check.
        def validate_bounded_keys!(value, required, allowed, label)
          raise ArgumentError, "#{label} must be a Hash" unless value.is_a?(Hash)
          return if (required - value.keys).empty? && (value.keys - allowed).empty?

          raise ArgumentError, "#{label} attributes are invalid"
        end
      end
    end
  end
end
