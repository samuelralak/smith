# frozen_string_literal: true

# Evals never name the provider gem: Smith's core reaches RubyLLM through its
# own seams, so nothing under lib/smith/evals/ does (slice-1a design, 1 and 18).
# Slice 1a.1's other files, canonical JSON and the scope type, do not either.
RSpec.describe "Evals and the provider gem" do
  lib = File.expand_path("../../../lib/smith", __dir__)

  it "is named by no file under lib/smith/evals/, nor by canonical JSON or the scope type" do
    files = Dir[File.join(lib, "evals", "**", "*.rb")] + %w[canonical_json.rb scope.rb].map { File.join(lib, _1) }

    expect(files.size).to be >= 8
    expect(files.select { |path| File.read(path).match?(/ruby_?llm/i) }).to eq([])
  end
end
