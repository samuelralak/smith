# frozen_string_literal: true

require_relative "schema_rules"

module Smith
  module Providers
    # Checks a parsed structured output against the constraints in its JSON
    # schema that SchemaConstraints may have kept from the provider:
    # numeric bounds and multiples, string lengths, array sizes and
    # uniqueness, and required properties, through properties, items,
    # local `$ref`s, `allOf`, `anyOf` (one alternative must accept the
    # value) and `oneOf` (exactly one must). When no alternative accepts a
    # value, the problems of the one alternative of its type are reported
    # if there is one. Each schema and value pair is judged once, so the
    # walk stays polynomial however deeply the output nests; it reports at
    # most MAX_PROBLEMS "path: problem" lines and stops descending after
    # MAX_VISITS visits.
    class SchemaConstraintCheck
      MAX_PROBLEMS = 20
      MAX_DEPTH = 64
      MAX_VISITS = 1_000_000
      include SchemaRules

      def initialize(root)
        @root = root
      end

      def call(value)
        @found = []
        @visits = 0
        @verdicts = {}
        check(@root, value, "", 0)
        @found.first(MAX_PROBLEMS)
      end

      private

      def check(schema, value, path, depth)
        return unless schema.is_a?(Hash) && depth <= MAX_DEPTH && @found.length < MAX_PROBLEMS
        return if (@visits += 1) > MAX_VISITS

        schema = resolve(schema)
        check_alternatives(schema, value, path, depth) if schema["anyOf"] || schema["oneOf"]
        Array(schema["allOf"]).each { check(_1, value, path, depth + 1) }
        check_value(schema, value, path, depth)
      end

      def check_value(schema, value, path, depth)
        own_problems(schema, value).each { |problem| report(path, problem) }
        check_children(schema, value, path, depth)
      end

      def report(path, problem) = @found << "#{path.empty? ? "/" : path}: #{problem}"

      def check_alternatives(schema, value, path, depth)
        alternatives = Array(schema["anyOf"] || schema["oneOf"]).map { resolve(_1) }
        accepted = alternatives.count { accepts?(_1, value, depth + 1) }
        return if schema["anyOf"] ? accepted.positive? : accepted == 1
        return report(path, "matches more than one of the allowed forms") if accepted > 1

        report_closest(alternatives, value, path, depth)
      end

      def report_closest(alternatives, value, path, depth)
        typed = alternatives.select { type?(_1["type"], value) }
        return report(path, "matches none of the allowed forms") unless typed.length == 1

        check(typed.first, value, path, depth + 1)
      end

      # Whether the alternative accepts the value, judged once per schema
      # and value.
      def accepts?(schema, value, depth)
        @verdicts.fetch([schema.object_id, value.object_id]) do |key|
          @verdicts[key] = type?(schema["type"], value) && trial(schema, value, depth)
        end
      end

      def trial(schema, value, depth)
        outer = @found
        @found = []
        check(schema, value, "", depth)
        @found.empty?
      ensure
        @found = outer
      end

      def check_children(schema, value, path, depth)
        case value
        when Hash
          Hash(schema["properties"]).each do |name, child|
            check(child, value[name], "#{path}/#{name}", depth + 1) if value.key?(name)
          end
        when Array
          value.each_with_index do |item, index|
            check(item_schema(schema, index), item, "#{path}/#{index}", depth + 1)
          end
        end
      end

      def item_schema(schema, index)
        tuple = schema["prefixItems"] || (schema["items"] if schema["items"].is_a?(Array))
        Array(tuple)[index] || (schema["items"] unless schema["items"].is_a?(Array))
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

      # A local JSON pointer `$ref` ("#" for the whole schema,
      # "#/$defs/name", "#/definitions/name", or deeper, as
      # "#/$defs/a/properties/b"); any other reference is left as the schema
      # it sits in.
      def resolve(schema)
        ref = schema["$ref"]
        return @root if ref == "#"
        return schema unless ref.is_a?(String) && ref.start_with?("#/")

        target = ref.delete_prefix("#/").split("/").reduce(@root) do |level, part|
          key = part.gsub("~1", "/").gsub("~0", "~")
          level.is_a?(Hash) ? level[key] : nil
        end
        target.is_a?(Hash) ? target : schema
      end
    end
  end
end
