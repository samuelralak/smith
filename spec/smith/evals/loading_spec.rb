# frozen_string_literal: true

require "json"
require "open3"

# Evals load on their own require, after Smith itself; nothing they add
# loads on `require "smith"`, and loading them installs their recorder
# (Smith::Evals::Recording, slice 1a.4) into the core's attempt seam, and
# nothing else. Each check runs in a child process, so nothing this suite
# loaded can hide a gap.
RSpec.describe "Loading evals" do
  lib = File.expand_path("../../../lib", __dir__)

  def child(lib, script)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
    raise "child failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  it "defines datasets, scorers, suites and a trial's pieces from require \"smith/evals\", and installs Recording" do
    facts = child(lib, <<~RUBY)
      require "json"
      require "smith/evals"
      names = %i[Error SuiteInvalid DatasetInvalid DatasetChanged SplitNotAllowed SubjectNotReady DriverUnsupported
                 ResumeMismatch RunBusy RecordCorrupt StoreError Configuration Identity Actor Sample SplitRule
                 DatasetManifest Dataset FileDataset Score Scorer Reducers Subject Suite SuiteManifest Statistics
                 Store Stores ScopeConflict TrialSpec TrialContext SubjectResult Trial Outcomes Recorder Recording
                 Driver Drivers Spend Summary Record EvalRun Plan Runner]
      print JSON.generate(
        "defined" => names.select { |name| Smith::Evals.const_defined?(name, false) },
        "experimental" => Smith::Evals::EXPERIMENTAL,
        "calls" => %i[run cancel record under].select { Smith::Evals.respond_to?(_1) },
        "config" => Smith::Evals.config.class.name,
        "stores" => Smith::Evals::Stores.constants.sort.map(&:to_s),
        "observer" => Smith::AttemptObservation.observer&.name,
        "drivers" => Smith::Evals::Drivers.constants.sort.map(&:to_s)
      )
    RUBY

    expect(facts).to eq(
      "defined" => %w[Error SuiteInvalid DatasetInvalid DatasetChanged SplitNotAllowed SubjectNotReady
                      DriverUnsupported ResumeMismatch RunBusy RecordCorrupt StoreError Configuration Identity Actor
                      Sample SplitRule DatasetManifest Dataset FileDataset Score Scorer Reducers Subject Suite
                      SuiteManifest Statistics Store Stores ScopeConflict TrialSpec TrialContext SubjectResult Trial
                      Outcomes Recorder Recording Driver Drivers Spend Summary Record EvalRun Plan Runner],
      "experimental" => true, "calls" => %w[run cancel record under], "config" => "Smith::Evals::Configuration",
      "stores" => %w[File Memory],
      "observer" => "Smith::Evals::Recording", "drivers" => %w[InProcess]
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
