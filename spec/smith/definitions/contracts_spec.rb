# frozen_string_literal: true

require "json"
require "smith/definitions"

# docs/schemas/smith-definition-1.json, the published form of definition
# format 1 (additions design 2.3): valid JSON Schema 2020-12; its examples,
# the reference documents and every document this slice writes valid as
# published and in the strict copy that refuses unknown fields (StatsSchema's
# rule); and what the schema can say of the fill-in fields, said as Smith
# says it.
RSpec.describe "The definition format's schema" do
  path = File.expand_path("../../../docs/schemas/smith-definition-1.json", __dir__)
  reference = JSON.parse(File.read(File.expand_path("../../fixtures/definitions/reference.json", __dir__)))

  let(:published) { JSON.parse(File.read(path)) }

  def errors(document, strict:)
    require "json_schemer"
    schema = JSON.parse(File.read(File.expand_path("../../../docs/schemas/smith-definition-1.json", __dir__)))
    JSONSchemer.schema(strict ? StatsSchema.strict(schema) : schema).validate(document).map { _1.fetch("error") }
  end

  def valid!(document, name)
    %i[open strict].each { expect(errors(document, strict: _1 == :strict)).to eq([]), "#{name} (#{_1})" }
  end

  it "is valid JSON Schema 2020-12, named by its URN" do
    require "json_schemer"

    expect(published.values_at("$schema", "$id"))
      .to eq(["https://json-schema.org/draft/2020-12/schema", "urn:smith:definition:1"])
    expect(JSONSchemer.valid_schema?(published)).to be(true)
  end

  it "publishes the design's agent and judge as its examples, each one Smith parses" do
    examples = published.fetch("examples")

    expect(examples.map { _1.values_at("kind", "id") }).to eq([%w[agent job-triage], %w[judge reason-cites-posting]])
    expect(examples).to eq(reference.fetch("documents").first(2).map { _1.fetch("document") })
    examples.each do |example|
      valid!(example, example.fetch("id"))
      expect(Smith::Definitions.parse(example).to_h).to eq(example)
    end
  end

  it "takes every reference document, and every document with_llm and replace_component write" do
    reference.fetch("documents").each { valid!(_1.fetch("document"), _1.fetch("name")) }
    doc = Smith::Definitions.parse(reference.dig("documents", 0, "document"))
    written = [doc.with_llm(provider: "openai", model: "gpt-5", settings: { thinking: { effort: "high" } }),
               doc.with_llm(provider: "anthropic", model: "claude-haiku-4-5"),
               doc.replace_component("triage.rules", "Sort the posting.")]

    written.each { valid!(_1.to_h, _1.digest) }
  end

  # What Smith refuses, the schema refuses wherever JSON Schema can say it,
  # in Ruby's reading of ^ and $ as in ECMAScript's; the rest its
  # description names.
  describe "against Smith's rules" do
    agent = reference.dig("documents", 0, "document")
    edge = reference.dig("documents", 4, "document")
    llm = agent.fetch("llm")
    outputs = agent.fetch("outputs")
    reason = outputs.dig("properties", "reason")
    with = ->(changes) { JSON.parse(JSON.generate(agent)).merge(changes) }
    shaped = ->(properties) { with.call("outputs" => outputs.merge("properties" => properties)) }

    expressed = {
      "a credential-named key in annotations" => with.call("annotations" => { "api_key" => "x" }),
      "one nested in a list" => with.call("annotations" => { "a" => [{ "githubTOKEN" => 1 }] }),
      "one on a component" => with.call("prompt" => [agent["prompt"][0].merge("annotations" => { "Client-Secret" =>
        "s" }), agent["prompt"][1]]),
      "one spelled with a Kelvin sign" => with.call("annotations" => { "TO\u212AEN" => 1 }),
      "an object open to other properties" => with.call("outputs" => outputs.except("additionalProperties")),
      "a nested one" => shaped.call("reason" => { "type" => %w[object null], "properties" => { "a" => reason },
                                                  "required" => ["a"] }),
      "an object with no properties" => shaped.call("reason" => { "type" => "object", "required" => [],
                                                                  "additionalProperties" => false }),
      "an object with no required" => with.call("outputs" => outputs.except("required")),
      "a $ref with a type beside it" => JSON.parse(JSON.generate(edge).sub('{"$ref":"#/$defs/money"}',
                                                                           '{"$ref":"#/$defs/money","type":"object"}')),
      "anyOf beside a type" => shaped.call("reason" => { "anyOf" => [reason], "type" => "string" }),
      "a schema with no type" => shaped.call("reason" => { "enum" => ["x"] }),
      "a model id with a line break" => with.call("llm" => llm.merge("model" => "claude\nsonnet")),
      "an id with a line break" => with.call("id" => "job\ntriage"),
      "an input title with a line break" => with.call("inputs" => [agent["inputs"][0].merge("title" => "a\nb"),
                                                                   agent["inputs"][1]]),
      "a repeated fallback" => with.call("llm" => llm.merge("fallbacks" => llm["fallbacks"] * 2)),
      "an output limit past 2**53 - 1" => with.call("llm" => llm.merge("settings" => { "max_output_tokens" => 2**53 })),
      "a number past 2**53 - 1" => with.call("annotations" => { "n" => 1e20 }),
      "a number needing an exponent" => with.call("annotations" => { "n" => [1, { "m" => 1e-7 }] })
    }

    expressed.each do |rule, document|
      it "refuses #{rule}, as Smith does" do
        expect(errors(document, strict: false)).not_to be_empty
        expect { Smith::Definitions.parse(document) }.to raise_error(Smith::DefinitionInvalid)
      end
    end

    described = {
      "of an input title used twice" => [with.call("inputs" => [agent["inputs"][0]] * 2), "unique"],
      "of 2.0 where an Integer is required" => [with.call("smith_definition" => 1.0), "without a fraction"],
      "of negative zero" => [with.call("annotations" => { "n" => -0.0 }), "negative zero"],
      "of a 70 KiB component" => [with.call("prompt" => [agent["prompt"][0].merge("text" => "x" * 70_000),
                                                         agent["prompt"][1]]), "64 KiB"],
      "of 201 fill-in fields" => [with.call("prompt" => [agent["prompt"][0], agent["prompt"][1].merge("text" =>
        "{{posting}} " * 201)]), "200 fill-in fields"],
      "of a fallback repeating the model" => [with.call("llm" => llm.merge("fallbacks" =>
        [llm.slice("provider", "model")])), "repeats neither the model"],
      "of a setting the model does not take" => [with.call("llm" => llm.merge("model" => "claude-opus-4-7")),
                                                 "each setting is one the model takes"],
      "of a property left out of required" => [with.call("outputs" => outputs.merge("required" => ["verdict"])),
                                               "list every property in required"]
    }

    described.each do |rule, (document, words)|
      it "names the rule #{rule} in its description" do
        expect(errors(document, strict: false)).to eq([])
        expect { Smith::Definitions.parse(document) }.to raise_error(Smith::DefinitionInvalid)
        expect(published.fetch("description")).to include(words)
      end
    end
  end

  it "refuses an unknown field, a workflow and each Mustache form, as Smith does" do
    agent = reference.dig("documents", 0, "document")
    refused = [agent.merge("tools" => []), agent.merge("kind" => "workflow"),
               agent.merge("llm" => agent.fetch("llm").merge("api_key" => "x"))]
    tags = ["{{#a}}", "{{^a}}", "{{/a}}", "{{>a}}", "{{!a}}", "{{{a}}}", "{{&a}}", "{{=| |=}}", "{{ a}}", "{{a"]
    refused += tags.map do |tag|
      component = { "component_id" => "c", "role" => "user", "text" => "x #{tag}" }
      agent.merge("prompt" => [agent.dig("prompt", 0), component])
    end

    refused.each do |document|
      expect(errors(document, strict: false)).not_to be_empty, document.inspect
      expect { Smith::Definitions.parse(document) }.to raise_error(Smith::DefinitionInvalid)
    end
  end
end
