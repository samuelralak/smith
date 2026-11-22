# frozen_string_literal: true

# RuboCop before 1.92 reads only the enable, disable, todo, push and pop
# modes. A newer mode such as disable-next is reported malformed there, and
# the cops it meant to silence fire, so the slice's files keep to the two
# modes every RuboCop in use reads.
RSpec.describe "The statistics' RuboCop directives" do
  lib = File.expand_path("../../../lib/smith", __dir__)

  it "use only disable and enable, which RuboCop 1.85 reads as 1.92 does" do
    files = Dir[File.join(lib, "evals", "**", "*.rb")] + %w[canonical_json.rb scope.rb].map { File.join(lib, _1) }
    modes = files.flat_map do |path|
      File.foreach(path).with_index(1).filter_map do |line, number|
        mode = line[/#\s*rubocop\s*:\s*([\w-]+)/, 1]
        "#{File.basename(path)}:#{number} #{mode}" if mode && !%w[disable enable].include?(mode)
      end
    end

    expect(files.size).to be >= 8
    expect(modes).to eq([])
  end
end
