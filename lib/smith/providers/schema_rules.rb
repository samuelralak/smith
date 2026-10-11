# frozen_string_literal: true

module Smith
  module Providers
    # The JSON schema rules SchemaConstraintCheck applies: numeric bounds
    # and multiples, and JSON types.
    module SchemaRules
      NUMBER_RULES = [
        ["minimum", ->(number, limit) { number < limit }, "is below the minimum %s"],
        ["maximum", ->(number, limit) { number > limit }, "is above the maximum %s"],
        ["exclusiveMinimum", ->(number, limit) { number <= limit }, "must be above %s"],
        ["exclusiveMaximum", ->(number, limit) { number >= limit }, "must be below %s"],
        ["multipleOf", ->(number, divisor) { divisor.positive? && !SchemaRules.multiple?(number, divisor) },
         "is not a multiple of %s"]
      ].freeze
      TYPES = {
        "object" => ->(value) { value.is_a?(Hash) }, "array" => ->(value) { value.is_a?(Array) },
        "string" => ->(value) { value.is_a?(String) }, "integer" => ->(value) { value.is_a?(Integer) },
        "number" => ->(value) { value.is_a?(Integer) || value.is_a?(Float) },
        "boolean" => ->(value) { [true, false].include?(value) }, "null" => lambda(&:nil?)
      }.freeze

      def self.multiple?(number, divisor)
        quotient = number / divisor.to_r
        quotient.denominator == 1 || (number.is_a?(Float) && (quotient - quotient.round).abs < 1e-9)
      end

      private

      def numeric?(setting) = setting.is_a?(Integer) || (setting.is_a?(Float) && setting.finite?)

      def type?(type, value)
        return true if type.nil?
        return Array(type).any? { type?(_1, value) } if type.is_a?(Array)

        TYPES.fetch(type, ->(_value) { true }).call(value)
      end
    end
  end
end
