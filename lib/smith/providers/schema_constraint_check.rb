# frozen_string_literal: true

require_relative "schema_rules"

module Smith
  module Providers
    # Checks a parsed structured output against the constraints in its JSON
    # schema that SchemaConstraints may have kept from the provider:
    # numeric bounds and multiples, string lengths, array sizes and
    # uniqueness, and required properties, through properties, items,
    # local `$ref`s, `allOf`, and `anyOf`/`oneOf` (a value passes when one
    # alternative of its type accepts it). Reports at most MAX_PROBLEMS
    # "path: problem" lines; walks at most MAX_DEPTH levels.
    class SchemaConstraintCheck
      MAX_PROBLEMS = 20
      MAX_DEPTH = 64
      include SchemaRules

      def initialize(root)
        @root = root
      end

      def call(value)
        @found = []
        check(@root, value, "", 0)
        @found.first(MAX_PROBLEMS)
      end

      private

      def check(schema, value, path, depth)
        return unless schema.is_a?(Hash) && depth <= MAX_DEPTH && @found.length < MAX_PROBLEMS

        schema = resolve(schema)
        return check_alternatives(schema, value, path, depth) if schema["anyOf"] || schema["oneOf"]

        Array(schema["allOf"]).each { check(_1, value, path, depth + 1) }
        check_value(schema, value, path, depth)
      end

      def check_value(schema, value, path, depth)
        own_problems(schema, value).each { |problem| report(path, problem) }
        check_children(schema, value, path, depth)
      end

      def report(path, problem) = @found << "#{path.empty? ? "/" : path}: #{problem}"

      def check_alternatives(schema, value, path, depth)
        return if Array(schema["anyOf"] || schema["oneOf"]).any? { accepts?(_1, value, depth + 1) }

        report(path, "matches none of the allowed forms")
      end

      # Checks the alternative into a list of its own.
      def accepts?(schema, value, depth)
        schema = resolve(schema)
        return false unless type?(schema["type"], value)

        outer = @found
        @found = []
        check(schema, value, "", depth)
        @found.empty?
      ensure
        @found = outer if outer
      end

      def check_children(schema, value, path, depth)
        case value
        when Hash
          Hash(schema["properties"]).each do |name, child|
            check(child, value[name], "#{path}/#{name}", depth + 1) if value.key?(name)
          end
        when Array
          value.each_with_index do |item, index|
            check(Array(schema["prefixItems"])[index] || schema["items"], item, "#{path}/#{index}", depth + 1)
          end
        end
      end

      def own_problems(schema, value)
        case value
        when Integer, Float then number_problems(schema, value)
        when String then size_problems(schema, value.length, "characters", "minLength", "maxLength")
        when Array then array_problems(schema, value)
        when Hash then Array(schema["required"]).reject { value.key?(_1) }.map { "is missing #{_1}" }
        else []
        end
      end

      def number_problems(schema, number)
        # NUMBER_RULES: [keyword, broken?(number, limit), message]
        NUMBER_RULES.filter_map do |keyword, broken, message|
          limit = schema[keyword]
          format(message, limit) if numeric?(limit) && broken.call(number, limit)
        end
      end

      def array_problems(schema, array)
        problems = size_problems(schema, array.length, "items", "minItems", "maxItems")
        problems << "has duplicate items" if schema["uniqueItems"] == true && array.uniq.length != array.length
        problems
      end

      def size_problems(schema, size, unit, min_key, max_key)
        [
          ("has fewer than #{schema[min_key]} #{unit}" if schema[min_key].is_a?(Integer) && size < schema[min_key]),
          ("has more than #{schema[max_key]} #{unit}" if schema[max_key].is_a?(Integer) && size > schema[max_key])
        ].compact
      end

      # A local `$ref` ("#/$defs/name" or "#/definitions/name"); any other
      # reference is left as the schema it sits in.
      def resolve(schema)
        ref = schema["$ref"]
        return schema unless ref.is_a?(String)

        _, section, name = ref.split("/", 3)
        target = @root.dig(section, name) if %w[$defs definitions].include?(section)
        target.is_a?(Hash) ? target : schema
      end
    end
  end
end
