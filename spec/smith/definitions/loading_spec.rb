# frozen_string_literal: true

require "json"
require "open3"

# Definitions load on their own require, after Smith itself; `require
# "smith"` loads none of them (additions design 2.13). They reach the
# provider gem only through Smith's own seams, and their RuboCop directives
# are ones RuboCop 1.85 reads as 1.92 does. Each load runs in a child
# process, so nothing this suite loaded can hide a gap.
RSpec.describe "Loading definitions" do
  lib = File.expand_path("../../../lib", __dir__)
  files = Dir[File.join(lib, "smith", "definitions", "**", "*.rb")] +
          %w[definitions.rb template.rb json_value.rb].map { File.join(lib, "smith", _1) }

  def child(lib, script)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
    raise "child failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  it "defines the format, its errors and the template from require \"smith/definitions\"" do
    facts = child(lib, <<~RUBY)
      require "json"
      require "smith/definitions"
      print JSON.generate(
        "definitions" => %i[FORMATS Document].select { Smith::Definitions.const_defined?(_1, false) },
        "smith" => %i[DefinitionInvalid Template TemplateValueMissing].select { Smith.const_defined?(_1, false) },
        "internal" => %i[Format Digests Validator].map { Smith::Definitions.const_defined?(_1, false) },
        "observer" => Smith::AttemptObservation.observer, "evals" => Smith.const_defined?(:Evals, false)
      )
    RUBY

    expect(facts).to eq("definitions" => %w[FORMATS Document],
                        "smith" => %w[DefinitionInvalid Template TemplateValueMissing],
                        "internal" => [true, true, true], "observer" => nil, "evals" => false)
  end

  it "loads none of it on require \"smith\"" do
    facts = child(lib, <<~RUBY)
      require "json"
      require "smith"
      names = %i[Definitions DefinitionInvalid Template TemplateValueMissing JSONValue]
      print JSON.generate("defined" => names.select { Smith.const_defined?(_1, false) || Smith.autoload?(_1) },
                          "files" => $LOADED_FEATURES.grep(%r{/lib/smith/(definitions|template|json_value)}))
    RUBY

    expect(facts).to eq("defined" => [], "files" => [])
  end

  it "loads the template and the digests alone, with no workflow code" do
    facts = child(lib, <<~RUBY)
      require "json"
      require "smith/template"
      require "smith/definitions/digests"
      print JSON.generate("workflow" => Smith.const_defined?(:Workflow, false),
                          "rendered" => Smith::Template.new("{{a}}!").render(a: "hi"))
    RUBY

    expect(facts).to eq("workflow" => false, "rendered" => "hi!")
  end

  it "names the provider gem in no file" do
    expect(files.size).to be >= 8
    expect(files.select { |file| File.read(file).match?(/ruby_?llm/i) }).to eq([])
  end

  it "uses only the RuboCop directives disable and enable" do
    modes = files.flat_map do |file|
      File.foreach(file).with_index(1).filter_map do |line, number|
        mode = line[/#\s*rubocop\s*:\s*([\w-]+)/, 1]
        "#{File.basename(file)}:#{number} #{mode}" if mode && !%w[disable enable].include?(mode)
      end
    end

    expect(modes).to eq([])
  end
end
