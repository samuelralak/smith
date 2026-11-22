# frozen_string_literal: true

require "json"
require "open3"

# The statistics load alone, with no workflow code and no observer; Smith
# itself loads none of this slice's constants. Each check runs in a child
# process, so nothing this suite loaded can hide a missing require.
RSpec.describe "Loading the statistics" do
  lib = File.expand_path("../../../lib", __dir__)

  def child(lib, script)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)
    raise "child failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  it "defines Smith::Evals::Statistics from its own require, without Smith's runtime or an observer" do
    facts = child(lib, <<~RUBY)
      require "json"
      before = $LOADED_FEATURES.dup
      require "smith/evals/statistics"
      sample = Smith::Evals::Statistics::Sample.new(id: "a", trials: [true])
      facts = {
        "statistics" => Smith::Evals::Statistics.estimate(samples: [sample], reducer: :any).n,
        "canonical_json" => !defined?(Smith::CanonicalJSON).nil?,
        "scope" => !defined?(Smith::Scope).nil?,
        "workflow" => !defined?(Smith::Workflow).nil?,
        "attempt_observation" => !defined?(Smith::AttemptObservation).nil?,
        "ruby_llm" => !defined?(RubyLLM).nil?,
        # What the require loaded (Bundler may already have read version.rb for the gemspec).
        "smith_files" => ($LOADED_FEATURES - before).grep(%r{/lib/smith/}).map { |path| path.split("/lib/smith/").last }.sort
      }
      require "smith"
      facts["observer_after_smith"] = Smith::AttemptObservation.observer
      print JSON.generate(facts)
    RUBY

    expect(facts).to eq(
      "statistics" => 1, "canonical_json" => true, "scope" => false, "workflow" => false,
      "attempt_observation" => false, "ruby_llm" => false, "observer_after_smith" => nil,
      "smith_files" => %w[canonical_json.rb error.rb evals/statistics.rb evals/statistics/beta.rb
                          evals/statistics/comparer.rb evals/statistics/comparing.rb
                          evals/statistics/comparison_set_builder.rb evals/statistics/display.rb
                          evals/statistics/distributions.rb evals/statistics/estimation.rb
                          evals/statistics/estimator.rb evals/statistics/formulas.rb
                          evals/statistics/formulas/agreement.rb evals/statistics/formulas/clusters.rb
                          evals/statistics/formulas/estimators.rb evals/statistics/formulas/intervals.rb
                          evals/statistics/formulas/paired.rb evals/statistics/formulas/readings.rb
                          evals/statistics/formulas/sizes.rb evals/statistics/inputs.rb
                          evals/statistics/inputs_digest.rb evals/statistics/judging.rb
                          evals/statistics/pairing.rb evals/statistics/resampling.rb evals/statistics/results.rb
                          evals/statistics/sample.rb evals/statistics/sample_list.rb evals/statistics/sizing.rb
                          evals/statistics/split_mix64.rb evals/statistics/student_t.rb]
    )
  end

  it "leaves Evals, CanonicalJSON, Scope and ScopeInvalid undefined under Smith after require \"smith\"" do
    facts = child(lib, <<~RUBY)
      require "json"
      require "smith"
      names = %i[Evals CanonicalJSON Scope ScopeInvalid]
      print JSON.generate(
        "defined" => names.select { |name| Smith.const_defined?(name, false) },
        "autoload" => names.select { |name| Smith.autoload?(name) },
        "files" => $LOADED_FEATURES.grep(%r{/lib/smith/(evals|canonical_json|scope)\\b})
      )
    RUBY

    expect(facts).to eq("defined" => [], "autoload" => [], "files" => [])
  end

  it "defines Smith::Scope and Smith::CanonicalJSON from their own requires alone" do
    facts = child(lib, <<~RUBY)
      require "json"
      require "smith/scope"
      print JSON.generate("scope" => Smith::Scope.build(tenant: "t").keys, "error" => Smith::ScopeInvalid.superclass.name,
                          "statistics" => !defined?(Smith::Evals).nil?, "workflow" => !defined?(Smith::Workflow).nil?)
    RUBY

    expect(facts).to eq("scope" => ["tenant"], "error" => "Smith::Error", "statistics" => false, "workflow" => false)
  end
end
