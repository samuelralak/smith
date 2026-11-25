# frozen_string_literal: true

require "json"
require "open3"

# Evals load on their own require, after Smith itself; nothing this slice
# adds loads on `require "smith"`, and in slice 1a.2 nothing is installed
# into the core's attempt seam (the recorder is slice 1a.4's). Each check
# runs in a child process, so nothing this suite loaded can hide a gap.
RSpec.describe "Loading evals" do
  lib = File.expand_path("../../../lib", __dir__)

  def child(lib, script)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
    raise "child failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  it "defines datasets, scorers and suites from require \"smith/evals\", and installs no observer" do
    facts = child(lib, <<~RUBY)
      require "json"
      require "smith/evals"
      names = %i[Error SuiteInvalid DatasetInvalid DatasetChanged SplitNotAllowed SubjectNotReady DriverUnsupported
                 ResumeMismatch RunBusy RecordCorrupt StoreError Configuration Identity Actor Sample SplitRule
                 DatasetManifest Dataset FileDataset Score Scorer Reducers Subject Suite SuiteManifest Statistics
                 Store Stores]
      print JSON.generate(
        "defined" => names.select { |name| Smith::Evals.const_defined?(name, false) },
        "experimental" => Smith::Evals::EXPERIMENTAL,
        "config" => Smith::Evals.config.class.name,
        "stores" => Smith::Evals::Stores.constants.sort.map(&:to_s),
        "observer" => Smith::AttemptObservation.observer
      )
    RUBY

    expect(facts).to eq(
      "defined" => %w[Error SuiteInvalid DatasetInvalid DatasetChanged SplitNotAllowed SubjectNotReady
                      DriverUnsupported ResumeMismatch RunBusy RecordCorrupt StoreError Configuration Identity Actor
                      Sample SplitRule DatasetManifest Dataset FileDataset Score Scorer Reducers Subject Suite
                      SuiteManifest Statistics Store Stores],
      "experimental" => true, "config" => "Smith::Evals::Configuration", "stores" => %w[File Memory],
      "observer" => nil
    )
  end

  it "loads none of it on require \"smith\"" do
    facts = child(lib, <<~RUBY)
      require "json"
      require "smith"
      print JSON.generate("evals" => Smith.const_defined?(:Evals, false), "autoload" => Smith.autoload?(:Evals),
                          "files" => $LOADED_FEATURES.grep(%r{/lib/smith/evals}))
    RUBY

    expect(facts).to eq("evals" => false, "autoload" => nil, "files" => [])
  end
end
