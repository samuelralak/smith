# frozen_string_literal: true

require "json"

require_relative "schema_constraint_check"

module Smith
  module Providers
    # Structured-output schemas and the constraints providers do not enforce.
    #
    # Anthropic's structured outputs reject numeric constraints (`minimum`,
    # `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`),
    # string lengths (`minLength`, `maxLength`) and array sizes beyond a
    # `minItems` of 0 or 1 (`maxItems`, `uniqueItems`), and need
    # `additionalProperties: false` on every object. `for_provider` sends
    # such a schema without them; `problems` checks them on the parsed
    # output, for every provider (SchemaConstraintCheck), so one schema
    # serves both the request and the check. Walks are bounded in depth.
    module SchemaConstraints
      STRIPPED = %w[minimum maximum exclusiveMinimum exclusiveMaximum multipleOf minLength maxLength maxItems
                    uniqueItems].freeze
      NESTED_LISTS = %w[anyOf allOf oneOf prefixItems].freeze
      NESTED_MAPS = %w[properties $defs definitions].freeze
      NESTED_SCHEMAS = %w[items not].freeze
      MAX_DEPTH = 64

      module_function

      # The JSON schema payload ({ "schema" => ..., with "name" and the
      # like when given }, String keys) of an output schema: a RubyLLM
      # schema class or instance, or a Hash. nil when it has none.
      def json_schema(output_schema)
        instance = output_schema.is_a?(Class) ? output_schema.new : output_schema
        raw = instance.respond_to?(:to_json_schema) ? instance.to_json_schema : instance
        return unless raw.is_a?(Hash)

        schema = JSON.parse(JSON.generate(raw))
        schema["schema"].is_a?(Hash) ? schema : { "schema" => schema }
      rescue StandardError
        nil
      end

      # The schema payload to send to `provider`: for Anthropic, without the
      # constraints it rejects and with closed objects; unchanged otherwise.
      def for_provider(payload, provider)
        return payload unless provider.to_s == "anthropic"

        payload.merge("schema" => strip(payload.fetch("schema"), 0))
      end

      # "path: problem" lines for each constraint the value breaks, at most
      # SchemaConstraintCheck::MAX_PROBLEMS.
      def problems(schema, value) = SchemaConstraintCheck.new(schema).call(value)

      def strip(schema, depth)
        return schema unless schema.is_a?(Hash) && depth <= MAX_DEPTH

        copy = schema.reject { |key, setting| STRIPPED.include?(key) || (key == "minItems" && setting.to_i > 1) }
        close_object!(copy)
        copy.to_h { |key, setting| [key, strip_nested(key, setting, depth)] }
      end

      def strip_nested(key, setting, depth)
        if (NESTED_LISTS.include?(key) || key == "items") && setting.is_a?(Array)
          setting.map { strip(_1, depth + 1) }
        elsif NESTED_MAPS.include?(key) && setting.is_a?(Hash) then setting.transform_values { strip(_1, depth + 1) }
        elsif NESTED_SCHEMAS.include?(key) then strip(setting, depth + 1)
        else setting
        end
      end

      # An object gets `additionalProperties: false`. One that allows other
      # properties, or declares none (a free-form map, which closed could
      # only be `{}`), cannot be sent and is refused before the call.
      def close_object!(schema)
        return unless Array(schema["type"]).include?("object") || schema.key?("properties")

        open = schema.key?("additionalProperties") && schema["additionalProperties"] != false
        if open || Hash(schema["properties"]).empty?
          raise Smith::WorkflowError, "Anthropic structured outputs need every object to declare its properties " \
                                      "and allow no others"
        end
        schema["additionalProperties"] = false
      end
    end
  end
end
