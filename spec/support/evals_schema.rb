# frozen_string_literal: true

require "json"

# Validates evals documents against docs/evals/schemas, as published and in
# a strict copy that refuses unknown fields (every object that lists
# properties gains additionalProperties: false), the way the contracts'
# validate.py checks the examples. Every schema is loaded by its URN $id, so
# their $refs resolve to one another; one published twice is an error.
module EvalsSchema
  DIRECTORY = File.expand_path("../../docs/evals/schemas", __dir__)
  PREFIX = "urn:smith:evals:1:"

  class << self
    # The error messages for one document against the named schema
    # ("sample", "dataset-manifest", "suite-manifest", ...), or against one
    # of its parts (`pointer`, "#/$defs/step").
    def errors(document, schema:, strict:, pointer: nil)
      validator = validator(schema, strict:)
      validator = validator.ref(pointer) if pointer
      validator.validate(document).map { |error| error.fetch("error") }
    end

    def documents
      @documents ||= Dir[File.join(DIRECTORY, "*.schema.json")].each_with_object({}) do |path, loaded|
        schema = JSON.parse(File.read(path))
        raise ArgumentError, "#{schema.fetch("$id")} is published twice" if loaded.key?(schema.fetch("$id"))

        loaded[schema.fetch("$id")] = schema
      end
    end

    private

    def validator(name, strict:)
      require "json_schemer"
      @validators ||= {}
      @validators[[name, strict]] ||= begin
        loaded = documents.transform_values { |document| strict ? StatsSchema.strict(document) : document }
        JSONSchemer.schema(loaded.fetch("#{PREFIX}#{name}"), ref_resolver: lambda { |uri|
          loaded.fetch(uri.to_s.split("#").first) { raise ArgumentError, "unknown schema #{uri}" }
        })
      end
    end
  end
end
