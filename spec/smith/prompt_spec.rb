# frozen_string_literal: true

require "digest"
require "open3"
require "tmpdir"

# A named prompt (plan 5.2): an agent's tunable text, inert, with a
# component id and a version that is its text's SHA-256.
RSpec.describe "Smith::Prompt" do
  let(:prompt_class) { require_const("Smith::Prompt") }

  it "names a component, keeps its text as given and versions it as definition format 1 versions a component" do
    require "smith/definitions"
    text = "You sort job postings for {{person}}.\n"
    prompt = prompt_class.new("triage.rules", text)
    document = Smith::Definitions.parse(
      { "smith_definition" => 1, "kind" => "agent", "id" => "triage",
        "inputs" => [{ "title" => "person", "type" => "string", "trust" => "trusted" }],
        "llm" => { "provider" => "anthropic", "model" => "claude-sonnet-4-6" },
        "prompt" => [{ "component_id" => "triage.rules", "role" => "system", "text" => text },
                     { "component_id" => "triage.case", "role" => "user", "text" => "Sort it." }] }
    )

    expect([prompt.component_id, prompt.text, prompt.fields]).to eq(["triage.rules", text, ["person"]])
    expect(prompt.version).to eq("sha256:#{Digest::SHA256.hexdigest(text)}")
    expect(prompt.version).to eq(document.component_versions.fetch("triage.rules"))
    expect([prompt, prompt.text, prompt.version, prompt.fields].all?(&:frozen?)).to be(true)
  end

  it "refuses a component id outside the definitions' rule, text that is not a template, and what is not text" do
    invalid = require_const("Smith::PromptInvalid")

    expect { prompt_class.new("Triage rules", "x") }.to raise_error(invalid, /component id/)
    expect { prompt_class.new("triage", "{{#each}}x{{/each}}") }.to raise_error(invalid, /a Mustache section/)
    expect { prompt_class.new("triage", :text) }.to raise_error(invalid, /a String/)
    expect { prompt_class.new("triage", "\xFF".b) }.to raise_error(invalid, /UTF-8/)
  end

  it "reads a file's text as it is: ERB and Ruby interpolation stay text, never run" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rules.md")
      File.write(path, "Rules <%= raise 'ran' %> \#{raise 'ran'} for {{person}}")

      prompt = prompt_class.file("triage.rules", path)
      expect(prompt.text).to eq("Rules <%= raise 'ran' %> \#{raise 'ran'} for {{person}}")
      expect([prompt.text.encoding, prompt.fields]).to eq([Encoding::UTF_8, ["person"]])
    end
  end

  it "takes another text for its component only when it keeps exactly the same fill-in fields" do
    invalid = require_const("Smith::PromptInvalid")
    prompt = prompt_class.new("triage.rules", "Sort for {{person}} by {{rules}}.")

    swapped = prompt.with_text("By {{ rules }}, sort for {{person}}; {{person}} again.")
    expect([swapped.component_id, swapped.fields.sort, swapped.version]).to eq(
      ["triage.rules", %w[person rules], "sha256:#{Digest::SHA256.hexdigest(swapped.text)}"]
    )
    expect { prompt.with_text("Sort for {{person}}.") }
      .to raise_error(invalid, "triage.rules: a new text keeps the fill-in fields {{person}}, {{rules}}; " \
                               "this one has {{person}}")
    expect { prompt.with_text("Sort for {{person}} by {{rules}} and {{extra}}.") }
      .to raise_error(invalid, /this one has \{\{extra\}\}, \{\{person\}\}, \{\{rules\}\}\z/)
    expect { prompt.with_text("Sort for {{someone}} by {{rules}}.") }
      .to raise_error(invalid, /this one has \{\{rules\}\}, \{\{someone\}\}\z/)
    expect { prompt.with_text("{{person}} {{rules}} {{> partial}}") }.to raise_error(invalid, /a partial/)
  end

  it "fills its fields in once, as they are: a value's own braces and ERB stay text" do
    prompt = prompt_class.new("triage.rules", "For {{person}}:")

    expect(prompt.render("person" => "{{person}} <%= 1 %>")).to eq("For {{person}} <%= 1 %>:")
  end

  it "loads with nothing else when named, and require \"smith\" loads none of it" do
    script = <<~RUBY
      before = $LOADED_FEATURES.dup
      require "smith"
      core = $LOADED_FEATURES - before
      print [core.grep(%r{/smith/(prompt|prompts/pins|template|canonical_json|content_identity)\\.rb\\z}).size,
             Smith::Prompts.__send__(:declared?), Smith.autoload?(:Prompt).nil?].inspect
      Smith::Prompt.new("a", "b")
      print [Smith.autoload?(:Prompt).nil?, Smith::Prompts.__send__(:declared?)].inspect
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script)

    expect([status.success?, err]).to eq([true, ""])
    expect(out).to eq("[0, false, false][true, false]")
  end
end
