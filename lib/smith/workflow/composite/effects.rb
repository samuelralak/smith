# frozen_string_literal: true

require_relative "../../types"
require_relative "../../budget/decimal_context"
require_relative "../message_value_normalizer"
require_relative "../prepared_step"
require_relative "payload"

module Smith
  class Workflow
    module Composite
      class Effects < Payload
        attr_reader :total_tokens, :total_cost

        USAGE_ATTRIBUTES = %w[
          usage_id agent_name model input_tokens output_tokens cost attempt_kind recorded_at
        ].freeze
        TOOL_ATTRIBUTES = %w[tool captured].freeze
        private_constant :USAGE_ATTRIBUTES, :TOOL_ATTRIBUTES

        attribute :usage_entries, Types::Array
        attribute :tool_results, Types::Array
        attribute :budget_consumed, Types::Hash

        def initialize(attributes)
          owned = self.class.normalize_attributes(attributes)
          normalized = MessageValueNormalizer.new(owned, label: "composite effects").call
          usage_entries = normalized.fetch("usage_entries")
          tool_results = normalized.fetch("tool_results")
          budget_consumed = normalized.fetch("budget_consumed")
          @total_tokens, @total_cost = validate_usage_entries!(usage_entries)
          validate_tool_results!(tool_results)
          validate_budget!(budget_consumed)
          super(
            usage_entries:,
            tool_results:,
            budget_consumed:
          )
        end

        private

        def validate_usage_entries!(entries)
          raise ArgumentError, "composite usage entries must be an Array" unless entries.is_a?(Array)

          entries.each do |entry|
            validate_exact_keys!(entry, USAGE_ATTRIBUTES, "composite usage entry")
            validate_usage_identity!(entry)
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
          validate_usage_id!(entry.fetch("usage_id"))
          validate_agent_name!(entry.fetch("agent_name"))
          %w[model attempt_kind recorded_at].each do |key|
            validate_nonempty_string!(entry.fetch(key), "composite usage entry #{key}")
          end
        end

        def validate_usage_id!(usage_id)
          return if usage_id.is_a?(String) && PreparedStep::UUID_PATTERN.match?(usage_id)

          raise ArgumentError, "composite usage entry usage_id must be a UUID"
        end

        def validate_agent_name!(agent_name)
          return if agent_name.nil?

          validate_nonempty_string!(agent_name, "composite usage entry agent_name")
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
          return if cost.nil?
          return if cost.is_a?(Numeric) && cost.finite? && cost >= 0

          raise ArgumentError, "composite usage entry cost must be a finite non-negative number or nil"
        end

        def validate_tool_results!(entries)
          raise ArgumentError, "composite tool results must be an Array" unless entries.is_a?(Array)

          entries.each do |entry|
            validate_exact_keys!(entry, TOOL_ATTRIBUTES, "composite tool result")
            tool = entry.fetch("tool")
            unless tool.is_a?(String) && tool.length.between?(1, 256)
              raise ArgumentError, "composite tool result tool must be a bounded non-empty String"
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

        def validate_exact_keys!(value, expected, label)
          raise ArgumentError, "#{label} must be a Hash" unless value.is_a?(Hash)
          return if value.keys.sort == expected.sort

          raise ArgumentError, "#{label} attributes are invalid"
        end
      end
    end
  end
end
