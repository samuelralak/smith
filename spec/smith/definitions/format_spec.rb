# frozen_string_literal: true

require "json"
require "smith/definitions"

# Definition format 1 (additions design 2.3): one passing document per
# kind, one failing document per rule with its exact "path: problem" lines,
# every Mustache form outside the subset refused, and every limit at and
# past its bound.
RSpec.describe "Definition format 1" do
  reference = JSON.parse(File.read(File.expand_path("../../fixtures/definitions/reference.json", __dir__)))
  documents = reference.fetch("documents").to_h { [_1.fetch("name"), _1.fetch("document")] }
  agent = documents.fetch("job-triage")
  judge = documents.fetch("reason-cites-posting")
  fill_in = "fill-in fields are {{name}} or {{ name }} only"
  kind_rule = "is not a kind this Smith reads; it reads agent and judge"
  id_rule = "is 1 to 128 lowercase letters, digits, \".\", \"_\" or \"-\", starting with a letter or digit"
  providers = "anthropic, azure, bedrock, deepseek, gemini, gpustack, mistral, ollama, openai, openrouter, " \
              "perplexity, vertexai, xai"
  credential_words = %w[API_KEY token Secret pass-word authorization credential github.Access_Tokens]

  def copy(value) = JSON.parse(JSON.generate(value))

  # The document with each JSON Pointer set to its value, or removed when
  # the value is :absent.
  def edit(document, changes)
    copy(document).tap do |edited|
      changes.each do |pointer, value|
        *parents, last = pointer.split("/").drop(1).map { _1.match?(/\A\d+\z/) ? _1.to_i : _1 }
        holder = parents.reduce(edited) { |node, key| node[key] }
        value == :absent ? holder.delete(last) : holder[last] = value
      end
    end
  end

  def problems_of(document)
    Smith::Definitions.parse(document)
    []
  rescue Smith::DefinitionInvalid => e
    e.problems
  end

  it "accepts the design's agent and judge, and every reference document" do
    documents.each_value { expect(problems_of(_1)).to eq([]) }
    expect(Smith::Definitions.parse(agent).kind).to eq("agent")
    expect(Smith::Definitions.parse(judge).kind).to eq("judge")
    expect(Smith::Definitions::FORMATS).to eq([1])
  end

  it "accepts a document's JSON text as it accepts the document" do
    expect(Smith::Definitions.parse(JSON.pretty_generate(agent)).to_h).to eq(agent)
  end

  cases = {
    "a document that is not an object" => [nil, ["/: is a JSON object, or its text, not Integer"]],
    "text that is not JSON" => ["{\"kind\": ", ["/: is not valid JSON"]],
    "text with a key twice" => ["{\"kind\": \"agent\", \"kind\": \"judge\"}",
                                ["/: is not valid JSON: a key appears twice"]],
    "text that is not an object" => ["[1, 2]", ["/: is a JSON object, or its text, not Array"]],
    "text with half a surrogate pair" => [JSON.generate(agent).sub('"Job triage"', '"Job \\udc00"'),
                                          ["/: is not valid JSON"]],
    "no format" => [{ "/smith_definition" => :absent }, ["/smith_definition: is required"]],
    "an unknown format" => [{ "/smith_definition" => 2 }, ["/smith_definition: is a format Smith builds: 1"]],
    "a format given as text" => [{ "/smith_definition" => "1" }, ["/smith_definition: is a format Smith builds: 1"]],
    "no kind" => [{ "/kind" => :absent }, ["/kind: is required"]],
    "a workflow, not built yet" => [{ "/kind" => "workflow" }, ["/kind: #{kind_rule}"]],
    "a kind no Smith knows" => [{ "/kind" => "tool" }, ["/kind: #{kind_rule}"]],
    "a kind that is not text" => [{ "/kind" => 1 }, ["/kind: #{kind_rule}"]],
    "an unknown field" => [{ "/tools" => [] },
                           ["/tools: is not a field of an agent (smith_definition, kind, id, name, description, " \
                            "inputs, outputs, llm, prompt, annotations)"]],
    "a secret-named field" => [{ "/llm/api_key" => "sk-ant-x" },
                               ["/llm/api_key: credentials are never part of a definition"]],
    "a secret-named field in annotations" => [{ "/annotations" => { "canvas" => { "openaiApiKey" => "sk-x" } } },
                                              ["/annotations/canvas/openaiApiKey: credentials are never part of a " \
                                               "definition"]],
    "a field named for each credential word" => [
      { "/annotations" => credential_words.to_h { [_1, 1] } },
      credential_words.map { "/annotations/#{_1}: credentials are never part of a definition" }
    ],
    "no id" => [{ "/id" => :absent }, ["/id: is required"]],
    "an id with capitals" => [{ "/id" => "Job-Triage" }, ["/id: #{id_rule}"]],
    "an id past 128 characters" => [{ "/id" => "a" * 129 }, ["/id: #{id_rule}"]],
    "an empty name" => [{ "/name" => "" }, ["/name: is a non-empty String"]],
    "a description that is not text" => [{ "/description" => 7 }, ["/description: is a non-empty String"]],
    "a version on an agent" => [{ "/version" => 1 },
                                ["/version: is not a field of an agent (smith_definition, kind, id, name, " \
                                 "description, inputs, outputs, llm, prompt, annotations)"]],
    "annotations that are not an object" => [{ "/annotations" => [] }, ["/annotations: is an object"]],
    "no inputs" => [{ "/inputs" => :absent }, ["/inputs: is required"]],
    "inputs that are not a list" => [{ "/inputs" => {} }, ["/inputs: is a list"]],
    "an input that is not an object" => [{ "/inputs/0" => "person_summary" },
                                         ["/inputs/0: is an object",
                                          "/prompt/1/text: {{person_summary}} is not a declared input"]],
    "an unknown input field" => [{ "/inputs/0/default" => "x" },
                                 ["/inputs/0/default: is not a field of an input (title, type, description, trust, " \
                                  "fence)"]],
    "an input without a title" => [{ "/inputs/1/title" => :absent },
                                   ["/inputs/1/title: is required",
                                    "/prompt/1/text: {{posting}} is not a declared input"]],
    "an input title that is not a field name" => [{ "/inputs/1/title" => "the posting" },
                                                  ["/inputs/1/title: is a fill-in field name: a letter or \"_\", " \
                                                   "then up to 63 letters, digits or \"_\"",
                                                   "/prompt/1/text: {{posting}} is not a declared input"]],
    "a reserved input name" => [{ "/inputs/1/title" => "context", "/prompt/1/text" => "{{context}}" },
                                ["/inputs/1/title: context is reserved (chat, prompt, context, model_id, provider, " \
                                 "endpoint_mode)"]],
    "an input declared twice" => [{ "/inputs/1/title" => "person_summary", "/prompt/1/text" => "{{person_summary}}" },
                                  ["/inputs/1/title: person_summary is declared twice"]],
    "an input without a type" => [{ "/inputs/0/type" => :absent }, ["/inputs/0/type: is required"]],
    "an input of an unknown type" => [{ "/inputs/0/type" => "text" },
                                      ["/inputs/0/type: is string, number, integer, boolean, object or array"]],
    "an empty input description" => [{ "/inputs/0/description" => "" },
                                     ["/inputs/0/description: is a non-empty String"]],
    "an unknown trust" => [{ "/inputs/0/trust" => "partly" }, ["/inputs/0/trust: is trusted or untrusted"]],
    "a fence that is not true or false" => [{ "/inputs/0/fence" => "yes" }, ["/inputs/0/fence: is true or false"]],
    "a fence on a trusted input" => [{ "/inputs/0/trust" => "trusted", "/inputs/0/fence" => true },
                                     ["/inputs/0/fence: fences only an untrusted input"]],
    "no llm" => [{ "/llm" => :absent }, ["/llm: is required"]],
    "an llm that is not an object" => [{ "/llm" => "claude" }, ["/llm: is an object"]],
    "an unknown llm field" => [{ "/llm/params" => {} },
                               ["/llm/params: is not a field of llm (provider, model, settings, fallbacks, " \
                                "assume_exists)"]],
    "no provider" => [{ "/llm/provider" => :absent }, ["/llm/provider: is required"]],
    "an unknown provider" => [{ "/llm/provider" => "acme" }, ["/llm/provider: is a provider Smith runs: #{providers}"]],
    "no model" => [{ "/llm/model" => :absent }, ["/llm/model: is required"]],
    "a model id with a control character" => [{ "/llm/model" => "claude\n" },
                                              ["/llm/model: is a model id: 1 to 256 characters, none of them a " \
                                               "control character"]],
    "a model id past 256 characters" => [{ "/llm/model" => "m" * 257 },
                                         ["/llm/model: is a model id: 1 to 256 characters, none of them a control " \
                                          "character"]],
    "assume_exists that is not true or false" => [{ "/llm/assume_exists" => 1 },
                                                  ["/llm/assume_exists: is true or false"]],
    "settings that are not an object" => [{ "/llm/settings" => [] }, ["/llm/settings: is an object"]],
    "an unknown setting" => [{ "/llm/settings/top_p" => 0.9 },
                             ["/llm/settings/top_p: is not a setting of format 1 (temperature, max_output_tokens, " \
                              "thinking)"]],
    "a temperature past 2" => [{ "/llm/settings/temperature" => 2.5 },
                               ["/llm/settings/temperature: is a number from 0 to 2"]],
    "a temperature given as text" => [{ "/llm/settings/temperature" => "0" },
                                      ["/llm/settings/temperature: is a number from 0 to 2"]],
    "an output limit of 0" => [{ "/llm/settings/max_output_tokens" => 0 },
                               ["/llm/settings/max_output_tokens: is an Integer of at least 1"]],
    "thinking with both an effort and a budget" => [{ "/llm/settings/thinking" => { "effort" => "low",
                                                                                    "budget" => 1024 } },
                                                    ["/llm/settings/thinking: is an object with one of effort " \
                                                     "or budget"]],
    "thinking with an unknown field" => [{ "/llm/settings/thinking" => { "level" => "low" } },
                                         ["/llm/settings/thinking/level: is not a field of thinking (effort, budget)",
                                          "/llm/settings/thinking: is an object with one of effort or budget"]],
    "an unknown effort" => [{ "/llm/model" => "claude-opus-4-7", "/llm/settings" => { "thinking" => { "effort" =>
      "max" } } }, ["/llm/settings/thinking/effort: is low, medium or high"]],
    "a budget of 0" => [{ "/llm/settings/thinking" => { "budget" => 0 } },
                        ["/llm/settings/thinking/budget: is an Integer of at least 1"]],
    "a temperature the model does not take" => [{ "/llm/model" => "claude-opus-4-7" },
                                                ["/llm/settings/temperature: claude-opus-4-7 does not take a " \
                                                 "temperature"]],
    "thinking on a model that does not think" => [{ "/llm/provider" => "openai", "/llm/model" => "gpt-4o",
                                                    "/llm/settings/thinking" => { "effort" => "low" } },
                                                  ["/llm/settings/thinking: gpt-4o does not think"]],
    "a thinking budget for a model that takes an effort" => [{ "/llm/model" => "claude-opus-4-7",
                                                               "/llm/settings" => { "thinking" => { "budget" =>
                                                                 2048 } } },
                                                             ["/llm/settings/thinking/budget: claude-opus-4-7 takes " \
                                                              "a thinking effort, not a budget"]],
    "a thinking effort for a model that takes a budget" => [{ "/llm/settings/thinking" => { "effort" => "high" } },
                                                            ["/llm/settings/thinking/effort: claude-sonnet-4-6 takes " \
                                                             "a thinking budget, not an effort"]],
    "an output limit Smith cannot set for the provider" => [{ "/llm/provider" => "deepseek",
                                                              "/llm/model" => "deepseek-chat" },
                                                            ["/llm/settings/max_output_tokens: Smith sets no output " \
                                                             "limit for deepseek"]],
    "fallbacks that are not a list" => [{ "/llm/fallbacks" => {} }, ["/llm/fallbacks: is a list"]],
    "a fallback that is not an object" => [{ "/llm/fallbacks/0" => "openai/gpt-5-mini" },
                                           ["/llm/fallbacks/0: is an object"]],
    "an unknown fallback field" => [{ "/llm/fallbacks/0/settings" => {} },
                                    ["/llm/fallbacks/0/settings: is not a field of a fallback (provider, model)"]],
    "a fallback without a provider" => [{ "/llm/fallbacks/0/provider" => :absent },
                                        ["/llm/fallbacks/0/provider: is required"]],
    "a fallback with an unknown provider" => [{ "/llm/fallbacks/0/provider" => "acme" },
                                              ["/llm/fallbacks/0/provider: is a provider Smith runs: #{providers}"]],
    "a fallback repeating the model" => [{ "/llm/fallbacks/0" => { "provider" => "anthropic",
                                                                   "model" => "claude-sonnet-4-6" } },
                                         ["/llm/fallbacks/0: repeats the model or an earlier fallback"]],
    "no prompt" => [{ "/prompt" => :absent }, ["/prompt: is required"]],
    "a prompt that is not a list" => [{ "/prompt" => "text" }, ["/prompt: is a list"]],
    "a prompt with no user component" => [{ "/prompt/1/role" => "system", "/inputs/1/trust" => "trusted",
                                            "/inputs/0/trust" => "trusted" },
                                          ["/prompt: holds no user component"]],
    "a component that is not an object" => [{ "/prompt/0" => "rules" }, ["/prompt/0: is an object"]],
    "an unknown component field" => [{ "/prompt/0/name" => "rules" },
                                     ["/prompt/0/name: is not a field of a prompt component (component_id, role, " \
                                      "text, annotations)"]],
    "a component without an id" => [{ "/prompt/0/component_id" => :absent }, ["/prompt/0/component_id: is required"]],
    "a component id with a space" => [{ "/prompt/0/component_id" => "triage rules" },
                                      ["/prompt/0/component_id: #{id_rule}"]],
    "a component id used twice" => [{ "/prompt/1/component_id" => "triage.rules" },
                                    ["/prompt/1/component_id: triage.rules is used twice"]],
    "a component without a role" => [{ "/prompt/0/role" => :absent }, ["/prompt/0/role: is required"]],
    "an assistant prefill" => [{ "/prompt/0/role" => "assistant" }, ["/prompt/0/role: is system or user"]],
    "a component without text" => [{ "/prompt/0/text" => :absent }, ["/prompt/0/text: is required"]],
    "a component of white space only" => [{ "/prompt/0/text" => " \n\t" },
                                          ["/prompt/0/text: is a String with more than white space"]],
    "a component whose text is not text" => [{ "/prompt/0/text" => ["a"] },
                                             ["/prompt/0/text: is a String with more than white space"]],
    "component annotations that are not an object" => [{ "/prompt/0/annotations" => "tuned" },
                                                       ["/prompt/0/annotations: is an object"]],
    "a Mustache section" => [{ "/prompt/1/text" => "{{#posting}}{{posting}}{{/posting}}" },
                             ["/prompt/1/text: {{# at line 1, column 1: a Mustache section; #{fill_in}",
                              "/prompt/1/text: {{/ at line 1, column 24: a section's closing; #{fill_in}"]],
    "a field naming no input" => [{ "/prompt/1/text" => "{{person_summary}} {{postng}}" },
                                  ["/prompt/1/text: {{postng}} is not a declared input"]],
    "an untrusted field in a system component" => [{ "/prompt/0/text" => "Rules for {{posting}}" },
                                                   ["/prompt/0/text: {{posting}} is an untrusted input, which a " \
                                                    "system component cannot hold"]],
    "a field with no trust in a system component" => [{ "/inputs/1/trust" => :absent,
                                                        "/prompt/0/text" => "Rules for {{posting}}" },
                                                      ["/prompt/0/text: {{posting}} is an untrusted input, which a " \
                                                       "system component cannot hold"]],
    "a number with no finite value" => [{ "/annotations" => { "x" => Float::NAN } },
                                        ["/annotations/x: is not a finite number"]],
    "negative zero" => [{ "/llm/settings/temperature" => -0.0 }, ["/llm/settings/temperature: is negative zero"]],
    "a number that needs an exponent" => [{ "/annotations" => { "x" => 1e-7, "y" => 1e21 } },
                                          ["/annotations/x: is a number whose shortest form needs an exponent",
                                           "/annotations/y: is a number whose shortest form needs an exponent"]],
    "an integer past 2**53 - 1" => [{ "/annotations" => { "x" => 2**53 } },
                                    ["/annotations/x: is a number beyond 2**53 - 1"]],
    "a float canonical JSON writes as an integer past 2**53 - 1" => [
      { "/annotations" => { "x" => 1e20, "y" => 2.0**53, "z" => -9.99e20 } },
      ["/annotations/x: is a number beyond 2**53 - 1", "/annotations/y: is a number beyond 2**53 - 1",
       "/annotations/z: is a number beyond 2**53 - 1"]
    ],
    "a value with no JSON form" => [{ "/annotations" => { "at" => Time.at(0) } },
                                    ["/annotations/at: is a Time, which has no JSON form"]],
    "a key that is not text" => [{ "/annotations" => { 1 => "x" } },
                                 ["/annotations: has a key that is not a String (Integer)"]],
    "a key given twice as a String and a Symbol" => [{ "/annotations" => { "x" => 1, x: 2 } },
                                                     ["/annotations: has the key \"x\" twice"]],
    "text that is not UTF-8" => [{ "/description" => "\xff".b }, ["/description: is not valid UTF-8"]]
  }

  cases.each do |rule, (change, expected)|
    it "refuses #{rule}" do
      document = case change
                 when nil then 42
                 when String then change
                 else edit(agent, change)
                 end

      expect(problems_of(document)).to eq(expected)
    end
  end

  describe "a judge" do
    judge_fields = "(smith_definition, kind, id, version, name, description, inputs, llm, prompt, annotations)"

    {
      "with outputs, which Smith fixes" => [{ "/outputs" => { "type" => "object" } },
                                            ["/outputs: is not a field of a judge #{judge_fields}"]],
      "without a version" => [{ "/version" => :absent }, ["/version: is required"]],
      "with a version of 0" => [{ "/version" => 0 }, ["/version: is an Integer from 1 to 9007199254740991"]],
      "with a version given as text" => [{ "/version" => "2" },
                                         ["/version: is an Integer from 1 to 9007199254740991"]]
    }.each do |rule, (change, expected)|
      it "is refused #{rule}" do
        expect(problems_of(edit(judge, change))).to eq(expected)
      end
    end

    it "may fence or not, but only an untrusted input" do
      expect(problems_of(edit(judge, "/inputs/0/fence" => false))).to eq([])
      expect(problems_of(edit(judge, "/inputs/0/trust" => "trusted", "/inputs/0/fence" => false)))
        .to eq(["/inputs/0/fence: fences only an untrusted input"])
    end
  end

  describe "outputs" do
    let(:base) { agent }

    def outputs(schema) = edit(base, "/outputs" => schema)

    let(:reason) { { "type" => "string" } }

    def object(properties, **more)
      { "type" => "object", "properties" => properties, "required" => properties.keys,
        "additionalProperties" => false }.merge(more.transform_keys(&:to_s))
    end

    it "takes the portable subset, with value constraints kept" do
      schema = object(
        { "a" => { "type" => %w[string null], "pattern" => "^x", "format" => "email", "minLength" => 1,
                   "maxLength" => 9, "description" => "d", "title" => "t" },
          "b" => { "type" => "array", "items" => { "$ref" => "#/$defs/n" }, "minItems" => 0, "maxItems" => 3,
                   "uniqueItems" => true },
          "c" => { "anyOf" => [{ "type" => "integer", "minimum" => 0, "maximum" => 9, "exclusiveMinimum" => -1,
                                 "exclusiveMaximum" => 10, "multipleOf" => 2 }, { "type" => "null" }] },
          "d" => { "type" => "string", "enum" => ["x", 1, 2.5, true, nil] } },
        "$defs": { "n" => object({ "v" => { "type" => "number" } }) }
      )

      expect(problems_of(outputs(schema))).to eq([])
      expect(problems_of(edit(agent, "/outputs" => :absent))).to eq([])
    end

    {
      "a root that is not an object schema" => [{ "type" => "array", "items" => { "type" => "string" } },
                                                ["/outputs: has type object at its root"]],
      "a root union" => [{ "anyOf" => [{ "type" => "string" }] }, ["/outputs: has type object at its root"]],
      "outputs that are not a schema" => [[], ["/outputs: is a schema (an object)"]],
      "a keyword outside the subset" => [{ "type" => "object", "properties" => { "a" => { "type" => "string",
                                                                                          "oneOf" => [] } },
                                           "required" => ["a"], "additionalProperties" => false },
                                         ["/outputs/properties/a/oneOf: is not a keyword of format 1's output " \
                                          "schemas"]],
      "an object open to other properties" => [{ "type" => "object", "properties" => { "a" => { "type" => "string" } },
                                                 "required" => ["a"] },
                                               ["/outputs: sets additionalProperties to false, as every object must"]],
      "a nested object open to other properties" => [
        { "type" => "object", "required" => ["a"], "additionalProperties" => false,
          "properties" => { "a" => { "type" => %w[object null], "required" => ["b"],
                                     "properties" => { "b" => { "type" => "string" } } } } },
        ["/outputs/properties/a: sets additionalProperties to false, as every object must"]
      ],
      "an object with no properties" => [{ "type" => "object", "properties" => {}, "required" => [],
                                           "additionalProperties" => false },
                                         ["/outputs: declares its properties, as every object must"]],
      "an optional property" => [{ "type" => "object", "properties" => { "a" => { "type" => "string" },
                                                                         "b" => { "type" => "string" } },
                                   "required" => ["a"], "additionalProperties" => false },
                                 ["/outputs/required: lists each property once, and nothing else (an optional one " \
                                  "is a union with null)"]],
      "a schema with no type" => [{ "type" => "object", "properties" => { "a" => { "enum" => ["x"] } },
                                    "required" => ["a"], "additionalProperties" => false },
                                  ["/outputs/properties/a: has a type"]],
      "an unknown type" => [{ "type" => "object", "properties" => { "a" => { "type" => "date" } },
                              "required" => ["a"], "additionalProperties" => false },
                            ["/outputs/properties/a/type: is string, number, integer, boolean, array, object, null, " \
                             "or a list of them"]],
      "anyOf beside a type" => [{ "type" => "object", "properties" => { "a" => { "type" => "string", "anyOf" =>
        [{ "type" => "string" }] } }, "required" => ["a"], "additionalProperties" => false },
                                ["/outputs/properties/a: takes no type or properties beside anyOf"]],
      "a reference to no definition" => [{ "type" => "object", "properties" => { "a" => { "$ref" => "#/$defs/x" } },
                                           "required" => ["a"], "additionalProperties" => false },
                                         ["/outputs/properties/a/$ref: names a definition in /outputs/$defs, as " \
                                          "#/$defs/<name>"]],
      "a reference elsewhere" => [{ "type" => "object", "properties" => { "a" => { "$ref" =>
        "https://example.com/s.json" } }, "required" => ["a"], "additionalProperties" => false },
                                  ["/outputs/properties/a/$ref: names a definition in /outputs/$defs, as " \
                                   "#/$defs/<name>"]],
      "a reference with a type beside it" => [{ "type" => "object", "properties" => { "a" => { "$ref" => "#/$defs/s",
                                                                                               "type" => "string" } },
                                                "required" => ["a"], "additionalProperties" => false,
                                                "$defs" => { "s" => { "type" => "string" } } },
                                              ["/outputs/properties/a: takes only description or title beside $ref"]],
      "definitions below the root" => [{ "type" => "object", "properties" => { "a" => { "type" => "string",
                                                                                        "$defs" => {} } },
                                         "required" => ["a"], "additionalProperties" => false },
                                       ["/outputs/properties/a/$defs: is only at the root"]],
      "a recursive definition" => [{ "type" => "object", "properties" => { "a" => { "$ref" => "#/$defs/node" } },
                                     "required" => ["a"], "additionalProperties" => false,
                                     "$defs" => { "node" => { "type" => "object",
                                                              "properties" => { "next" => { "anyOf" =>
                                                                [{ "$ref" => "#/$defs/node" },
                                                                 { "type" => "null" }] } },
                                                              "required" => ["next"],
                                                              "additionalProperties" => false } } },
                                   ["/outputs/$defs/node: refers to itself, directly or through other definitions"]],
      "a definition name with a slash" => [{ "type" => "object", "properties" => { "a" => { "type" => "string" } },
                                             "required" => ["a"], "additionalProperties" => false,
                                             "$defs" => { "a/b" => { "type" => "string" } } },
                                           ["/outputs/$defs/a~1b: is a definition name: a letter or \"_\", then up " \
                                            "to 63 letters, digits, \".\", \"_\" or \"-\""]],
      "an empty enum" => [{ "type" => "object", "properties" => { "a" => { "type" => "string", "enum" => [] } },
                            "required" => ["a"], "additionalProperties" => false },
                          ["/outputs/properties/a/enum: is a non-empty list of strings, numbers, booleans or null"]],
      "an enum holding an object or a list" => [
        { "type" => "object", "required" => %w[a b], "additionalProperties" => false,
          "properties" => { "a" => { "type" => "object", "enum" => [{ "x" => 1 }] },
                            "b" => { "type" => "array", "enum" => [[1]] } } },
        ["/outputs/properties/a: sets additionalProperties to false, as every object must",
         "/outputs/properties/a: declares its properties, as every object must",
         "/outputs/properties/a/enum: is a non-empty list of strings, numbers, booleans or null",
         "/outputs/properties/b/enum: is a non-empty list of strings, numbers, booleans or null"]
      ],
      "a type list naming a type twice" => [{ "type" => "object", "properties" => { "a" => { "type" =>
        %w[string string] } }, "required" => ["a"], "additionalProperties" => false },
                                            ["/outputs/properties/a/type: is string, number, integer, boolean, " \
                                             "array, object, null, or a list of them"]],
      "items that are not a schema" => [{ "type" => "object", "properties" => { "a" => { "type" => "array",
                                                                                         "items" => [] } },
                                          "required" => ["a"], "additionalProperties" => false },
                                        ["/outputs/properties/a/items: is a schema (an object)"]],
      "constraints of the wrong kind" => [{ "type" => "object", "properties" => { "a" => {
        "type" => "string", "minLength" => -1, "pattern" => 3, "minimum" => "0", "multipleOf" => 0,
        "uniqueItems" => "no", "description" => 1
      } }, "required" => ["a"], "additionalProperties" => false },
                                          ["/outputs/properties/a/minLength: is an Integer of at least 0",
                                           "/outputs/properties/a/pattern: is a String",
                                           "/outputs/properties/a/minimum: is a number",
                                           "/outputs/properties/a/multipleOf: is a number above 0",
                                           "/outputs/properties/a/uniqueItems: is true or false",
                                           "/outputs/properties/a/description: is a String"]]
    }.each do |rule, (schema, expected)|
      it "refuses #{rule}" do
        expect(problems_of(outputs(schema))).to eq(expected)
      end
    end

    it "nests at most 10 levels" do
      nested = ->(levels) { levels == 1 ? reason : object({ "a" => nested.call(levels - 1) }) }

      expect(problems_of(outputs(nested.call(10)))).to eq([])
      expect(problems_of(outputs(nested.call(11)))).to eq(["/outputs: nests more than 10 levels"])
      # The root, then d9 to d1 at levels 2 to 10.
      chain = (1..9).to_h { ["d#{_1}", _1 == 1 ? reason : object({ "a" => { "$ref" => "#/$defs/d#{_1 - 1}" } })] }
      through_refs = object({ "a" => { "$ref" => "#/$defs/d9" } }, "$defs": chain)
      expect(problems_of(outputs(through_refs))).to eq([])
      through_refs["$defs"]["d1"] = object({ "a" => reason })
      expect(problems_of(outputs(through_refs))).to eq(["/outputs: nests more than 10 levels"])
    end
  end

  describe "fill-in fields" do
    forms = { "{{#a}}" => "{{# at line 2, column 3: a Mustache section",
              "{{^a}}" => "{{^ at line 2, column 3: an inverted section",
              "{{/a}}" => "{{/ at line 2, column 3: a section's closing",
              "{{>a}}" => "{{> at line 2, column 3: a partial",
              "{{!a}}" => "{{! at line 2, column 3: a comment",
              "{{{a}}}" => "{{{ at line 2, column 3: triple braces",
              "{{&a}}" => "{{& at line 2, column 3: an unescaped tag",
              "{{=| |=}}" => "{{= at line 2, column 3: a delimiter change",
              "{{ posting}}" => "{{ at line 2, column 3: not a fill-in field",
              "{{a.b}}" => "{{ at line 2, column 3: not a fill-in field" }

    forms.each do |tag, problem|
      it "refuses #{tag} in a component, at its position" do
        text = "{{person_summary}}\n- #{tag} {{posting}}"

        expect(problems_of(edit(agent, "/prompt/1/text" => text))).to eq(["/prompt/1/text: #{problem}; #{fill_in}"])
      end
    end

    it "takes {{name}} and {{ name }} alike" do
      doc = Smith::Definitions.parse(edit(agent, "/prompt/1/text" => "{{ person_summary }} {{posting}}"))

      expect(doc.placeholders("triage.case")).to eq(Set["person_summary", "posting"])
    end
  end

  describe "limits" do
    let(:limits) { Smith::Definitions.const_get(:Format) }
    let(:base) { agent }

    def padded(bytes)
      size = Smith::CanonicalJSON.generate(edit(base, "/annotations" => { "pad" => "" })).bytesize
      edit(base, "/annotations" => { "pad" => "x" * (bytes - size) })
    end

    it "takes a document of 1 MiB of canonical JSON, and refuses one byte more" do
      expect(Smith::CanonicalJSON.generate(padded(1_048_576)).bytesize).to eq(1_048_576)
      expect(problems_of(padded(1_048_576))).to eq([])
      expect(problems_of(padded(1_048_577))).to eq(["/: is more than 1048576 bytes of JSON"])
    end

    it "reads JSON text of at most 1 MiB" do
      text = JSON.generate(padded(1_048_576))

      expect(problems_of(text)).to eq([])
      expect(problems_of("#{text} ")).to eq(["/: is more than 1048576 bytes of JSON"])
    end

    it "takes 32 levels of nesting, and refuses 33" do
      nested = ->(levels) { levels.zero? ? 1 : [nested.call(levels - 1)] }
      # The document is level 1 and its annotations level 2.
      deepest = "/annotations/a#{"/0" * 30}"

      expect(problems_of(edit(agent, "/annotations" => { "a" => nested.call(30) }))).to eq([])
      expect(problems_of(edit(agent, "/annotations" => { "a" => nested.call(31) })))
        .to eq(["#{deepest}: nests deeper than 32 levels"])
      expect(problems_of(JSON.generate(edit(agent, "/annotations" => { "a" => nested.call(70) }))))
        .to eq(["/: nests deeper than 32 levels"])
    end

    it "takes 20,000 JSON values, and refuses one more" do
      count = lambda do |value|
        items = value.is_a?(Hash) ? value.values : value
        1 + (items.is_a?(Array) ? items.sum(&count) : 0)
      end
      room = limits::MAX_VALUES - count.call(edit(agent, "/annotations" => { "a" => [] }))

      expect(problems_of(edit(agent, "/annotations" => { "a" => [0] * room }))).to eq([])
      expect(problems_of(edit(agent, "/annotations" => { "a" => [0] * (room + 1) })))
        .to eq(["/: holds more than 20000 JSON values"])
    end

    it "takes a component of 64 KiB, and refuses one byte more" do
      head = "{{person_summary}} {{posting}} "

      expect(problems_of(edit(agent, "/prompt/1/text" => head + ("x" * (65_536 - head.bytesize))))).to eq([])
      expect(problems_of(edit(agent, "/prompt/1/text" => head + ("x" * (65_537 - head.bytesize)))))
        .to eq(["/prompt/1/text: is more than 65536 bytes"])
    end

    it "takes 200 fill-in fields in a component, and refuses 201" do
      expect(problems_of(edit(agent, "/prompt/1/text" => "{{posting}} " * 200))).to eq([])
      expect(problems_of(edit(agent, "/prompt/1/text" => "{{posting}} " * 201)))
        .to eq(["/prompt/1/text: holds more than 200 fill-in fields"])
    end

    # A line shows a document's key or value whole up to 64 characters,
    # else its first 64 and its length, so a message stays small whatever
    # the document holds: 100 problems under one long key, at 9,000 and at
    # 900,000 characters.
    it "keeps every problem line short, whatever the document's keys and values" do
      tokens = (1..100).to_h { ["token#{_1}", 1] }
      errors = [9_000, 900_000].map do |length|
        Smith::Definitions.parse(edit(agent, "/annotations" => { "k" * length => tokens }))
      rescue Smith::DefinitionInvalid => e
        e
      end

      expect(errors.map { _1.problems.size }).to eq([100, 100])
      expect(errors.map { _1.message.bytesize }).to all(be < 16 * 1024)
      expect(errors.first.problems.first).to eq("/annotations/#{"k" * 64}…(9000 characters)/token1: credentials " \
                                                "are never part of a definition")
      long_model = edit(agent, "/llm/model" => "m" * 200, "/llm/settings" => { "thinking" => { "effort" => "low" } })
      expect(problems_of(long_model)).to eq(["/llm/settings/thinking: #{"m" * 64}…(200 characters) does not think"])
      twice = edit(agent, "/annotations" => { ("x" * 70) => 1, ("x" * 70).to_sym => 2 })
      expect(problems_of(twice)).to eq(["/annotations: has the key \"#{"x" * 64}…(70 characters)\" twice"])
    end

    it "lists at most 100 problems" do
      many = edit(agent, "/inputs" => Array.new(150) { { "title" => "x y" } })

      expect(problems_of(many).size).to eq(100)
      expect { Smith::Definitions.parse(many) }.to raise_error(Smith::DefinitionInvalid, /\Athe definition is invalid/)
    end
  end
end
