# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require_relative "../../script/golden/commit_source"

# The shared "no difference" harness (slice-1a design, section 3.5): every
# scenario of script/core_invisibility_golden, run on this tree in a child
# process, against the golden file generated from the released gem in its
# own bundle (script/golden/Gemfile). A core change that an app not using it
# could notice fails here.
module CoreInvisibilityHarness
  ROOT = File.expand_path("../..", __dir__)
  GOLDEN = File.join(ROOT, "spec/fixtures/core_invisibility_golden.json")
  # A method a slice adds to the four classes is a `smith_` name or one of
  # these public DSL macros. No slice adds a constant a host body can see,
  # overrides a name Object or Kernel has, or removes a method.
  DSL_MACROS = %w[provider_credentials].freeze
  # Each change a slice makes to the host surface, "+ <class> <table> <name>";
  # slice 0 makes none.
  SURFACE_CHANGES = [].freeze
  # Paths whose every provider attempt a trial must observe.
  OBSERVED_PATHS = %w[parallel_branches fan_out nested_workflow optimize orchestrate image_answer nested_items
                      image_refusal_fallback repair_exhausted].freeze

  @runs = {}

  class << self
    def golden = @golden ||= JSON.parse(File.read(GOLDEN))

    # One child process per mode, shared by the examples.
    def run(mode)
      @runs[mode] ||= begin
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.join(ROOT, "lib"),
                                                File.join(ROOT, "script/core_invisibility_golden"), "--mode", mode)
        raise "harness (#{mode}) failed: #{stderr}" unless status.success?

        JSON.parse(stdout)
      end
    end

    def text(value) = JSON.pretty_generate(value)

    # The first differing lines, with a little context, so a failure reads.
    def diff(expected, actual)
      left = text(expected).lines
      right = text(actual).lines
      at = left.each_index.find { left[_1] != right[_1] } || left.length
      context = ([at - 3, 0].max)..(at + 3)
      ["first difference at line #{at + 1}\n", "golden:\n", *left[context], "build:\n", *right[context]].join
    end

    # The versions that differ from those the golden file was made under,
    # which name the likely cause of a difference.
    def drift(expected, actual)
      changed = expected.reject { |name, version| actual[name] == version }
      return "" if changed.empty?

      "versions differ from the golden's (#{changed.map { |name, was| "#{name} #{actual[name]}, golden #{was}" }
        .join("; ")})\n"
    end

    def provider_calls(scenario)
      scenario["traces"].select { _1[":type"] == ":provider_call" }.map { _1[":data"] }
    end

    def tally(entries, key) = entries.map { key ? _1[key] : _1.first }.tally

    # Every name added ("+") or removed ("-") in each table of the surface.
    def surface_changes(expected, actual)
      expected.flat_map do |klass, tables|
        leaves(tables).flat_map do |path, names|
          now = actual.fetch(klass).dig(*path)
          ((now - names).map { "+ #{klass} #{path.join(" ")} #{_1}" } +
            (names - now).map { "- #{klass} #{path.join(" ")} #{_1}" })
        end
      end
    end

    # A change the rule allows: an added method named `smith_` or a listed
    # DSL macro.
    def allowed?(change)
      sign, _klass, table, *, name = change.split
      sign == "+" && %w[instance singleton].include?(table) &&
        (name.start_with?("smith_") || DSL_MACROS.include?(name))
    end

    def leaves(tree, path = [])
      return [[path, tree]] if tree.is_a?(Array)

      tree.flat_map { |key, value| leaves(value, [*path, key]) }
    end
  end
end

RSpec.describe "Smith core invisibility: an app that does not use the eval seam sees no difference" do
  let(:golden) { CoreInvisibilityHarness.golden }

  def expect_golden_scenarios(document)
    scenarios = document["scenarios"]
    expect(scenarios.keys).to eq(golden["scenarios"].keys)
    golden["scenarios"].each { |name, expected| expect_same(name, expected, scenarios[name], document["environment"]) }
  end

  def expect_same(name, expected, actual, environment)
    harness = CoreInvisibilityHarness
    expect(harness.text(actual)).to eq(harness.text(expected)),
                                    "#{name}: #{harness.drift(golden["environment"], environment)}" \
                                    "#{harness.diff(expected, actual)}"
  end

  it "has a golden file generated from the commit the slice is built on, over twenty-three scenarios, every sink" do
    # 6bd0609, the orchestrate and usage fixes on 0.16.0
    # (script/core_invisibility_golden says where a golden comes from).
    expect(golden["smith"]).to eq("version" => "0.16.0", "source" => "commit",
                                  "commit" => "6bd060932a6e73b3a50244eaa1909d254eef36e9")
    expect(golden["process"]["attempt_observation"]).to be(false)
    expect(golden["scenarios"].keys).to eq(
      %w[serial_output_schema tool_loop parallel_branches fan_out route nested_workflow inline_call_child optimize
         orchestrate streamed batch fallback_after_overload output_repair budget_ledger memo_replay budget_pause
         durable_await durable_retry image_answer nested_items image_unkept image_refusal_fallback repair_exhausted]
    )
    sinks = %w[random_draws counts requests memo batches states persisted artifacts usage_entries traces events
               stream ledger logs errors results]
    golden["scenarios"].each_value { expect(_1.keys).to eq(sinks) }
    seen = golden["scenarios"].values
    %w[requests states persisted artifacts usage_entries traces events memo batches stream ledger errors].each do |sink|
      expect(seen.count { _1[sink].any? }).to be_positive, "no scenario fed #{sink}"
    end
    # Steps that end failed, an image's among them, so the golden holds
    # their persisted failure records.
    failed = golden["scenarios"].select { |_name, scenario| scenario["persisted"].to_s.include?("error_message") }
    expect(failed.keys).to include("image_unkept", "repair_exhausted")
    expect(seen.sum { _1["counts"].values.sum }).to be_positive
    # The one error a scenario means to raise (the memo replay's kill). Any
    # other is a crash, which a regenerated golden must not hold.
    errored = golden["scenarios"].reject { |_name, scenario| scenario["errors"].empty? }
    expect(errored.transform_values { |scenario| scenario["errors"].map { _1["class"] } })
      .to eq("memo_replay" => ["CoreInvisibility::Hosts::Killed"])
  end

  describe "a golden file written from a named commit" do
    let(:source) { CoreInvisibility::CommitSource }
    let(:script) { File.join(CoreInvisibilityHarness::ROOT, "script/core_invisibility_golden") }

    before do
      skip "needs this repository's git history" unless
        system("git", "-C", CoreInvisibilityHarness::ROOT, "rev-parse", "-q", "--verify", "HEAD", out: File::NULL)
    end

    def unbundled(*command) = Bundler.with_unbundled_env { Open3.capture3(*command) }

    # The script runs in this bundle, as a contributor runs it, vendored or
    # not; it hands its golden bundle the gems it sees.
    def scripted(*arguments) = Open3.capture3(RbConfig.ruby, script, *arguments)

    # HEAD is the commit a slice is built on while it is being built, and the
    # slice's own commit once committed, which promises the same scenarios.
    it "comes from a git archive of the commit in its own bundle, names the commit, and gives the golden's scenarios" do
      head = `git -C #{CoreInvisibilityHarness::ROOT} rev-parse HEAD`.strip
      version = `git -C #{CoreInvisibilityHarness::ROOT} show HEAD:lib/smith/version.rb`[/VERSION = "([^"]+)"/, 1]
      Dir.mktmpdir do |dir|
        path = File.join(dir, "golden.json")
        _out, err, status = scripted("--write", path, "--commit", "HEAD")
        expect([status.success?, err]).to eq([true, ""])
        written = JSON.parse(File.read(path))

        expect(written["smith"]).to eq("version" => version, "source" => "commit", "commit" => head)
        harness = CoreInvisibilityHarness
        expect(harness.text(written["scenarios"])).to eq(harness.text(golden["scenarios"]))
      end
    end

    it "refuses an archive with a file changed, added or gone or code in its Gemfile, an unknown commit, a tree" do
      Dir.mktmpdir do |dir|
        source.extract("HEAD", dir)
        source.bundle!(dir)
        version = File.join(dir, "lib/smith/version.rb")
        kept = File.read(version)
        File.write(version, "#{kept}# changed\n")
        changed = unbundled(*source.writer(dir, File.join(dir, "changed.json")))
        File.write(version, kept)
        File.write(File.join(dir, "lib/smith/extra.rb"), "# added\n")
        added = unbundled(*source.writer(dir, File.join(dir, "added.json")))
        File.delete(File.join(dir, "lib/smith/extra.rb"))
        readme = File.read(File.join(dir, "README.md"))
        File.delete(File.join(dir, "README.md"))
        gone = unbundled(*source.writer(dir, File.join(dir, "gone.json")))
        File.write(File.join(dir, "README.md"), readme)
        File.write(File.join(dir, source::GEMFILE), "#{source::GEMFILE_TEXT}ENV[\"SMITH_GOLDEN_PLANTED\"] = \"1\"\n")
        planted = unbundled(*source.writer(dir, File.join(dir, "planted.json")))

        [changed, added, gone, planted].each do |(_out, err, status)|
          expect([status.success?, err]).to match([false, /not other/])
        end
        expect(Dir.children(dir)).not_to include("changed.json", "added.json", "gone.json", "planted.json")
      end
      _out, err, status = scripted("--write", File::NULL, "--commit", "no-such-commit")
      expect([status.success?, err]).to match([false, /git rev-parse/])
      _out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(CoreInvisibilityHarness::ROOT, "lib"), script,
                                         "--write", File::NULL)
      expect([status.success?, err]).to match([false, /not tree/])
    end
  end

  it "matches the golden file byte for byte in a child process without the observer, which sees no seam in use" do
    plain = CoreInvisibilityHarness.run("plain")

    expect(plain["smith"]["source"]).to eq("tree")
    expect(plain["process"]).to eq("evals_defined" => false, "attempt_observation" => true,
                                   "observer_installed" => false, "empty_attribution_fields" => {})
    expect_golden_scenarios(plain)
  end

  it "adds no name a host's Workflow, Agent, Context or Tool subclass could collide with, and removes none" do
    changes = CoreInvisibilityHarness.surface_changes(golden["host_surface"],
                                                      CoreInvisibilityHarness.run("plain")["host_surface"])

    expect(changes).to eq(CoreInvisibilityHarness::SURFACE_CHANGES)
    expect(CoreInvisibilityHarness::SURFACE_CHANGES.reject { CoreInvisibilityHarness.allowed?(_1) }).to eq([])
  end

  it "never calls an installed observer outside a trial, and changes nothing" do
    observed = CoreInvisibilityHarness.run("observer")

    expect(observed["process"]["observer_installed"]).to be(true)
    expect(observed["observations"].values.sum(&:length)).to eq(0)
    expect_golden_scenarios(observed)
  end

  it "inside a trial changes nothing, draws no random number, and observes each provider attempt once" do
    trial = CoreInvisibilityHarness.run("trial")
    expect_golden_scenarios(trial)

    trial["scenarios"].each do |name, scenario|
      traced = CoreInvisibilityHarness.provider_calls(scenario)
      observed = trial["observations"].fetch(name).map { _1["attempt_id"] }
      # A child run the inline launcher runs apart from the parent's
      # attribution is not followed (design 3.3); every other attempt is.
      traced = traced.reject { _1[":workflow"] == "GoldenCallChildWorkflow" } if name == "inline_call_child"
      expect(observed).to eq(traced.map { _1[":attempt_id"] }), name
    end
    CoreInvisibilityHarness::OBSERVED_PATHS.each do |name|
      expect(trial["observations"].fetch(name).length).to be >= 2, name
    end
  end

  it "observes each attempt where it ran, with Smith's reading of how it ended" do
    observations = CoreInvisibilityHarness.run("trial")["observations"]
    position = ->(name, key) { observations.fetch(name).map { _1["position"][":#{key}"] } }

    # Smith names fan-out branches; a parallel: true branch has no key.
    expect(position.call("parallel_branches", "transition")).to eq([":find"] * 3)
    expect(position.call("fan_out", "branch_key")).to eq(%w[:left :middle :right])
    expect(position.call("optimize", "round")).to eq([0, 0, 1, 1])
    expect(position.call("nested_workflow", "workflow")).to eq(%w[GoldenNestedChildWorkflow GoldenNestedWorkflow])
    expect(position.call("inline_call_child", "workflow")).to eq(%w[GoldenCallWorkflow])
    first, second = observations.fetch("fallback_after_overload")
    expect([first["outcome"], first["failure"][":kind"], first["model"]]).to eq(%w[failed :transient claude-sonnet-5-5])
    expect([second["outcome"], second["model"]]).to eq(%w[completed claude-haiku-5-5])
    expect(observations.fetch("output_repair").map { [_1["outcome"], _1["sent_count"]] })
      .to eq([["completed", 2], ["completed", 4]])
    expect(observations.fetch("tool_loop").sole["tool_call_names"]).to eq(%w[golden_lookup golden_lookup])
    expect(observations.fetch("streamed").sole["mode"]).to eq("stream")
    expect(observations.fetch("batch").sole["mode"]).to eq("batch")
    expect(observations.fetch("memo_replay").sole["memo"]).to be(true)
    expect(observations.fetch("budget_pause").map { _1["outcome"] }).to eq(%w[aborted completed])
    expect(observations.fetch("durable_retry").first["failure"][":kind"]).to eq(":transient")
    # An image agent's attempts paint, and a throttled one falls back.
    painted = observations.fetch("image_answer")
    expect(painted.map { [_1["outcome"], _1["model"], _1["roles"]] })
      .to eq([["completed", "gpt-image-test", %w[user assistant]], ["failed", "gpt-image-test", %w[user]],
              ["completed", "gpt-image-other", %w[user assistant]]])
    expect(painted[1]["failure"][":kind"]).to eq(":transient")
    # A fan-out over items: one nested run an item, each in its own branch.
    expect(position.call("nested_items", "workflow")).to eq(%w[GoldenRoomWorkflow] * 3)
    expect(position.call("nested_items", "branch_key")).to eq([0, 1, 2])
    # The failure paths: an image that cannot be kept, a moderation block
    # taken to a refusal fallback, and an output that fails after its repair.
    unkept = observations.fetch("image_unkept").sole
    expect([unkept["outcome"], unkept["failure"][":kind"], unkept["failure"][":error_class"], unkept["roles"]])
      .to eq(["aborted", ":aborted", "Smith::OutputInvalid", %w[user]])
    expect(observations.fetch("image_refusal_fallback").map { [_1["model"], _1["stop_reason"], _1["roles"]] })
      .to eq([["gpt-image-test", "moderation_blocked", %w[user]], ["gpt-image-other", nil, %w[user assistant]]])
    expect(observations.fetch("repair_exhausted").map { [_1["outcome"], _1["sent_count"]] })
      .to eq([["completed", 2], ["completed", 4]])
  end

  it "under real concurrency, matches the golden file's parallel and fan-out runs by counts and branch content" do
    concurrent = CoreInvisibilityHarness.run("concurrent")
    expect(concurrent["scenarios"].keys).to eq(%w[parallel_branches fan_out nested_items])

    concurrent["scenarios"].each do |name, scenario|
      expected = golden["scenarios"].fetch(name)
      expect(scenario["requests"].map(&:last).sort).to eq(expected["requests"].map(&:last).sort), name
      expect(scenario["random_draws"]).to eq(expected["random_draws"]), name
      expect(CoreInvisibilityHarness.tally(scenario["traces"], ":type"))
        .to eq(CoreInvisibilityHarness.tally(expected["traces"], ":type")), name
      expect(CoreInvisibilityHarness.tally(scenario["events"], nil))
        .to eq(CoreInvisibilityHarness.tally(expected["events"], nil)), name
      expect(scenario["usage_entries"].map(&:length)).to eq(expected["usage_entries"].map(&:length)), name
      expect(scenario["results"]).to eq(expected["results"]), name
      expect(scenario["states"].last[":context"]).to eq(expected["states"].last[":context"]), name
      observed = concurrent["observations"].fetch(name).map { _1["attempt_id"] }.sort
      expect(observed).to eq(CoreInvisibilityHarness.provider_calls(scenario).map { _1[":attempt_id"] }.sort), name
    end
  end
end
