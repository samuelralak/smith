# frozen_string_literal: true

require "json"
require "open3"

# The tuner loads on its own require, after evals (slice 5a design, section
# 2): nothing of it on `require "smith"`, no name added to the core's
# Workflow, Agent, Context or Tool, no observer installed, and no file of it
# naming the provider gem or using a RuboCop directive 1.85 cannot read.
# The loading checks run in a child process, so nothing this suite loaded
# can hide a gap.
RSpec.describe "Loading the tuner" do
  lib = File.expand_path("../../../lib", __dir__)
  files = Dir[File.join(lib, "smith", "tuning", "**", "*.rb")] << File.join(lib, "smith", "tuning.rb")

  def child(lib, script)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
    raise "child failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  it "defines the tuner from require \"smith/tuning\", with evals, and adds nothing to the core or its observer" do
    facts = child(lib, <<~RUBY)
      require "json"
      require "smith/evals"
      observer = Smith::AttemptObservation.observer
      core = %w[Workflow Agent Context Tool].to_h do |name|
        klass = Smith.const_get(name)
        [name, [klass.constants.sort, klass.singleton_methods.sort, klass.public_instance_methods.sort].map { _1.map(&:to_s) }]
      end
      require "smith/tuning"
      after = %w[Workflow Agent Context Tool].to_h do |name|
        klass = Smith.const_get(name)
        [name, [klass.constants.sort, klass.singleton_methods.sort, klass.public_instance_methods.sort].map { _1.map(&:to_s) }]
      end
      print JSON.generate(
        "names" => Smith::Tuning.constants.sort.map(&:to_s), "experimental" => Smith::Tuning::EXPERIMENTAL,
        "core_unchanged" => core == after, "observer_unchanged" => Smith::AttemptObservation.observer.equal?(observer)
      )
    RUBY

    expect(facts).to eq(
      "names" => %w[Candidate EXPERIMENTAL Evaluation Loop Minibatches Pool Record Reflection Settings Split
                    SplitRefused],
      "experimental" => true, "core_unchanged" => true, "observer_unchanged" => true
    )
  end

  it "loads none of it on require \"smith\"" do
    facts = child(lib, <<~RUBY)
      require "json"
      require "smith"
      print JSON.generate("tuning" => Smith.const_defined?(:Tuning, false), "autoload" => Smith.autoload?(:Tuning),
                          "files" => $LOADED_FEATURES.grep(%r{/lib/smith/tuning}))
    RUBY

    expect(facts).to eq("tuning" => false, "autoload" => nil, "files" => [])
  end

  it "names the provider gem in no file" do
    expect(files.size).to be >= 9
    expect(files.select { |path| File.read(path).match?(/ruby_?llm/i) }).to eq([])
  end

  it "uses only the disable and enable RuboCop directives, which 1.85 reads as 1.92 does" do
    modes = files.flat_map do |path|
      File.foreach(path).with_index(1).filter_map do |line, number|
        mode = line[/#\s*rubocop\s*:\s*([\w-]+)/, 1]
        "#{File.basename(path)}:#{number} #{mode}" if mode && !%w[disable enable].include?(mode)
      end
    end

    expect(modes).to eq([])
  end
end
