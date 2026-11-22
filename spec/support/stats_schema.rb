# frozen_string_literal: true

require "json"

# Validates smith.evals.stats/1 results against docs/evals/schemas, as
# published and in a strict copy that refuses unknown fields (every object
# that lists properties gains additionalProperties: false), the way the
# contracts' validate.py checks the examples. A result validates against
# its type's $defs entry; the schema has no root type.
module StatsSchema
  DIRECTORY = File.expand_path("../../docs/evals/schemas", __dir__)
  COMMON = "urn:smith:evals:1:common"

  class << self
    def documents
      @documents ||= %w[stats common].to_h do |name|
        [name, JSON.parse(File.read(File.join(DIRECTORY, "#{name}.schema.json")))]
      end
    end

    # The error messages for one result's to_h, as published (strict:
    # false) or with unknown fields refused (strict: true).
    def errors(result, strict:)
      validator(result.fetch("type"), strict:).validate(result).map { |error| error.fetch("error") }
    end

    def strict(node)
      case node
      when Hash
        copy = node.transform_values { |value| strict(value) }
        copy["properties"] && !copy.key?("additionalProperties") ? copy.merge("additionalProperties" => false) : copy
      when Array then node.map { |value| strict(value) }
      else node
      end
    end

    private

    def validator(type, strict:)
      @validators ||= {}
      @validators[[type, strict]] ||= root(strict).ref("#/$defs/#{type}")
    end

    def root(strict)
      require "json_schemer"
      @roots ||= {}
      @roots[strict] ||= begin
        stats, common = documents.values_at("stats", "common").map { |document| strict ? strict(document) : document }
        JSONSchemer.schema(stats, ref_resolver: lambda { |uri|
          raise ArgumentError, "unknown schema #{uri}" unless uri.to_s.start_with?(COMMON)

          common
        })
      end
    end
  end
end
