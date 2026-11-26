# frozen_string_literal: true

require "json"
require "smith/definitions"

# The Document API (additions design 2.4): a parsed, frozen definition, its
# digests and fill-in fields, a component rewritten with the same fields, and
# a model variant that keeps the prompt.
RSpec.describe Smith::Definitions::Document do
  reference = JSON.parse(File.read(File.expand_path("../../fixtures/definitions/reference.json", __dir__)))
  documents = reference.fetch("documents").to_h { [_1.fetch("name"), _1.fetch("document")] }

  let(:written) { documents.fetch("job-triage") }
  let(:doc) { Smith::Definitions.parse(written) }

  it "answers its kind and id, and gives back the document as written, frozen" do
    expect([doc.kind, doc.id]).to eq(%w[agent job-triage])
    expect(doc.to_h).to eq(written)
    expect(doc.to_h).to be_frozen
    expect(doc.to_h.dig("prompt", 0, "text")).to be_frozen
    expect(doc).to be_frozen
    expect(doc.component_versions).to be_frozen
    expect(doc.component_versions.keys).to eq(%w[triage.rules triage.case])
  end

  it "loads what it was given, and nothing else: no default is written in" do
    sparse = documents.fetch("polite-reply")
    parsed = Smith::Definitions.parse(sparse)

    expect(parsed.to_h).to eq(sparse)
    expect(Smith::Definitions.parse(JSON.generate(parsed.to_h)).to_h).to eq(sparse)
    expect(parsed.to_h.dig("inputs", 0)).to eq("title" => "reply", "type" => "string", "fence" => false)
  end

  it "keeps no reference to what the host passed in" do
    given = JSON.parse(JSON.generate(written))
    parsed = Smith::Definitions.parse(given)
    given["prompt"][0]["text"] << " Changed later."
    given["llm"]["model"] = "claude-opus-4-7"

    expect(parsed.to_h).to eq(written)
    expect(parsed.digest).to eq(doc.digest)
  end

  # Settings are checked when a definition is created or imported, never
  # when a stored one is read back: a Smith release that learns a model
  # drops a setting must not strand the runs saved under it.
  describe "a stored definition" do
    let(:profile) do
      lambda do |temperature|
        Smith::Models::Profile.new(model_id: "house-model", provider: :openai, thinking_shape: nil,
                                   accepts_temperature: temperature, tools_with_thinking_native: false,
                                   tools_with_thinking_route: nil)
      end
    end

    after { Smith::Models.clear! }

    it "reads back after Smith's model table changes, though a new one is refused" do
      Smith::Models.register(profile.call(true))
      written = doc.with_llm(provider: "openai", model: "house-model", settings: { temperature: 0 })
      stored = JSON.generate(written.to_h)
      Smith::Models.clear!
      Smith::Models.register(profile.call(false))

      read = Smith::Definitions.parse(stored, stored: true)
      expect([read.digest, read.to_h]).to eq([written.digest, written.to_h])
      expect { Smith::Definitions.parse(stored) }
        .to raise_error(Smith::DefinitionInvalid, %r{/llm/settings/temperature: house-model does not take})
      expect { read.with_llm(provider: "openai", model: "house-model", settings: { temperature: 0 }) }
        .to raise_error(Smith::DefinitionInvalid, /house-model does not take a temperature/)
    end

    it "is held to every other rule, the llm's included" do
      llm = written.fetch("llm")
      broken = {
        { "tools" => [] } => "/tools: is not a field of an agent",
        { "llm" => llm.merge("provider" => "acme") } => "/llm/provider: is a provider Smith runs",
        { "llm" => llm.merge("model" => "claude\n") } => "/llm/model: is a model id",
        { "llm" => llm.merge("settings" => { "temperature" => "0" }) } => "/llm/settings/temperature: is a number",
        { "llm" => llm.merge("settings" => { "thinking" => { "effort" => "max" } }) } =>
          "/llm/settings/thinking/effort: is low, medium or high",
        { "llm" => llm.merge("fallbacks" => [llm.slice("provider", "model")]) } =>
          "/llm/fallbacks/0: repeats the model"
      }

      broken.each do |change, line|
        expect { Smith::Definitions.parse(written.merge(change), stored: true) }
          .to raise_error(Smith::DefinitionInvalid) { expect(_1.problems).to match([start_with(line)]) }
      end
    end

    it "says it was read as stored, which nothing it derives is, and takes only true or false" do
      stored = Smith::Definitions.parse(written, stored: true)

      expect([stored.stored?, doc.stored?, stored.with_llm(**llm_of(written)).stored?]).to eq([true, false, false])
      expect([stored.digest, stored.to_h]).to eq([doc.digest, doc.to_h])
      ["yes", nil, 1].each do |flag|
        expect { Smith::Definitions.parse(written, stored: flag) }
          .to raise_error(ArgumentError, "stored is true or false")
      end
    end

    def llm_of(document) = document.fetch("llm").slice("provider", "model").transform_keys(&:to_sym)
  end

  describe "#placeholders" do
    it "names a component's fill-in fields" do
      expect(doc.placeholders("triage.case")).to eq(Set["person_summary", "posting"])
      expect(doc.placeholders("triage.rules")).to eq(Set[])
      expect(doc.placeholders("triage.case")).to be_frozen
    end

    it "refuses a component the document does not hold" do
      expect { doc.placeholders("triage.cases") }.to raise_error(KeyError, "no prompt component triage.cases")
    end
  end

  describe "#replace_component" do
    it "gives a new document with the text replaced, its fill-in fields the same" do
      text = "Someone looks for work:\n{{ person_summary }}\n\nA posting ({{posting}}), again: {{posting}}"
      other = doc.replace_component("triage.case", text)

      expect(other).to be_a(described_class)
      expect(other.to_h.dig("prompt", 1, "text")).to eq(text)
      expect(other.to_h.except("prompt")).to eq(written.except("prompt"))
      expect(other.digest).not_to eq(doc.digest)
      expect(doc.to_h.dig("prompt", 1, "text")).to eq(written.dig("prompt", 1, "text"))
    end

    it "takes the same fill-in fields in another order" do
      other = doc.replace_component("triage.case", "{{posting}}, for {{person_summary}}")

      expect(other.placeholders("triage.case")).to eq(doc.placeholders("triage.case"))
    end

    it "refuses a text that drops or adds a fill-in field" do
      expect { doc.replace_component("triage.case", "The posting:\n{{posting}}") }
        .to raise_error(Smith::DefinitionInvalid) { |error|
          expect(error.problems).to eq(["/prompt/1/text: a new text keeps the fill-in fields {{person_summary}}, " \
                                        "{{posting}}; this one has {{posting}}"])
        }
      expect { doc.replace_component("triage.rules", "Rules. {{posting}}") }
        .to raise_error(Smith::DefinitionInvalid) { |error|
          expect(error.problems).to eq(["/prompt/0/text: {{posting}} is an untrusted input, which a system " \
                                        "component cannot hold"])
        }
    end

    it "refuses a text the format refuses" do
      expect { doc.replace_component("triage.case", "{{#posting}}{{person_summary}}{{posting}}{{/posting}}") }
        .to raise_error(Smith::DefinitionInvalid, %r{/prompt/1/text: \{\{# at line 1, column 1: a Mustache section})
      expect { doc.replace_component("triage.case", nil) }
        .to raise_error(Smith::DefinitionInvalid, %r{/prompt/1/text: is a String})
      expect { doc.replace_component("missing", "x") }.to raise_error(KeyError, "no prompt component missing")
    end
  end

  describe "#with_llm" do
    let(:variant) do
      doc.with_llm(provider: "openai", model: "gpt-5", settings: { thinking: { effort: :low }, max_output_tokens: 800 },
                   fallbacks: [{ provider: :anthropic, model: "claude-haiku-4-5" }])
    end

    it "changes only the llm block: the same prompt digest and component versions, a new digest" do
      expect(variant.to_h.except("llm")).to eq(written.except("llm"))
      expect(variant.to_h.fetch("llm")).to eq(
        "provider" => "openai", "model" => "gpt-5",
        "settings" => { "thinking" => { "effort" => "low" }, "max_output_tokens" => 800 },
        "fallbacks" => [{ "provider" => "anthropic", "model" => "claude-haiku-4-5" }]
      )
      expect([variant.prompt_digest, variant.component_versions]).to eq([doc.prompt_digest, doc.component_versions])
      expect(variant.digest).not_to eq(doc.digest)
    end

    it "writes the four llm fields it is given, and none the old llm had" do
      edge = Smith::Definitions.parse(documents.fetch("edge-cases"))
      plain = edge.with_llm(provider: "anthropic", model: "claude-haiku-4-5")

      expect(edge.to_h.dig("llm", "assume_exists")).to be(true)
      expect(plain.to_h.fetch("llm").keys).to eq(%w[provider model settings fallbacks])
    end

    it "writes settings and fallbacks out even when empty, so a variant has one spelling" do
      plain = doc.with_llm(provider: "anthropic", model: "claude-haiku-4-5")

      expect(plain.to_h.fetch("llm"))
        .to eq("provider" => "anthropic", "model" => "claude-haiku-4-5", "settings" => {}, "fallbacks" => [])
    end

    it "parses and builds like any other document" do
      again = Smith::Definitions.parse(JSON.generate(variant.to_h))

      expect([again.digest, again.prompt_digest]).to eq([variant.digest, variant.prompt_digest])
    end

    it "refuses a setting the new model does not take, naming the model" do
      expect { doc.with_llm(provider: "anthropic", model: "claude-opus-4-7", settings: { temperature: 0 }) }
        .to raise_error(Smith::DefinitionInvalid) { |error|
          expect(error.problems).to eq(["/llm/settings/temperature: claude-opus-4-7 does not take a temperature"])
        }
      expect { doc.with_llm(provider: "openai", model: "gpt-4.1", settings: { thinking: { budget: 1024 } }) }
        .to raise_error(Smith::DefinitionInvalid, %r{/llm/settings/thinking: gpt-4.1 does not think})
      expect { doc.with_llm(provider: "acme", model: "x") }
        .to raise_error(Smith::DefinitionInvalid, %r{/llm/provider: is a provider Smith runs})
    end

    it "checks settings against a model's profile a host registered" do
      profile = Smith::Models::Profile.new(model_id: "house-model", provider: :openai,
                                           thinking_shape: :reasoning_effort, accepts_temperature: false,
                                           tools_with_thinking_native: false, tools_with_thinking_route: nil)
      Smith::Models.register(profile)

      expect { doc.with_llm(provider: "openai", model: "house-model", settings: { temperature: 0 }) }
        .to raise_error(Smith::DefinitionInvalid, /house-model does not take a temperature/)
      expect(doc.with_llm(provider: "openai", model: "house-model", settings: { thinking: { effort: "high" } }).id)
        .to eq("job-triage")
    ensure
      Smith::Models.clear!
    end
  end
end
