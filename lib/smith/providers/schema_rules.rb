# frozen_string_literal: true

require "bigdecimal"

module Smith
  module Providers
    # The JSON schema rules SchemaConstraintCheck applies: numeric bounds
    # and multiples, array sizes and uniqueness, and JSON types.
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
        "string" => ->(value) { value.is_a?(String) },
        "integer" => ->(value) { value.is_a?(Integer) || SchemaRules.integral_float?(value) },
        "number" => ->(value) { value.is_a?(Integer) || value.is_a?(Float) },
        "boolean" => ->(value) { [true, false].include?(value) }, "null" => lambda(&:nil?)
      }.freeze

      # Compared as the decimals written in the schema and the output, so
      # 5 is a multiple of 0.01 and 0.3 of 0.1.
      def self.integral_float?(value) = value.is_a?(Float) && value.finite? && value == value.floor

      def self.multiple?(number, divisor)
        quotient = BigDecimal(number.to_s) / BigDecimal(divisor.to_s)
        (quotient - quotient.round).abs < BigDecimal("1e-9")
      end

      private

      def numeric?(setting) = setting.is_a?(Integer) || (setting.is_a?(Float) && setting.finite?)

      def array_problems(schema, array)
        problems = size_problems(schema, array.length, "items", "minItems", "maxItems")
        problems << "has duplicate items" if schema["uniqueItems"] == true && duplicates?(array)
        problems
      end

      # 1 and 1.0 are the same JSON number.
      def duplicates?(array)
        normalized = array.map { |item| SchemaRules.integral_float?(item) ? item.to_i : item }
        normalized.uniq.length != normalized.length
      end

      def size_problems(schema, size, unit, min_key, max_key)
        [
          ("has fewer than #{schema[min_key]} #{unit}" if schema[min_key].is_a?(Integer) && size < schema[min_key]),
          ("has more than #{schema[max_key]} #{unit}" if schema[max_key].is_a?(Integer) && size > schema[max_key])
        ].compact
      end

      def type?(type, value)
        return true if type.nil?
        return Array(type).any? { type?(_1, value) } if type.is_a?(Array)

        TYPES.fetch(type, ->(_value) { true }).call(value)
      end
    end
  end
end
