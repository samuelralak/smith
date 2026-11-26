# frozen_string_literal: true

require "json"

# Validates evals documents against docs/evals/schemas, as published and in
# a strict copy that refuses unknown fields (every object that lists
# properties gains additionalProperties: false), the way the contracts'
# validate.py checks the examples. Every schema is loaded by its URN $id, so
# their $refs resolve to one another. The record schemas (header, segment,
# trial, summary) are copied from the slice 1a contracts into
# spec/fixtures/evals/schemas for the stores' specs until slice 1a.5
# publishes them; a schema in both places is an error, so that move drops
# the copies.
module EvalsSchema
  DIRECTORY = File.expand_path("../../docs/evals/schemas", __dir__)
  FIXTURES = File.expand_path("../fixtures/evals/schemas", __dir__)
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
      @documents ||= [DIRECTORY, FIXTURES].flat_map { Dir[File.join(_1, "*.schema.json")] }
                                          .each_with_object({}) do |path, loaded|
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
