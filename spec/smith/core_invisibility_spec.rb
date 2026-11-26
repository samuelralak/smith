# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tempfile"
require "tmpdir"
require_relative "../../script/golden/git_source"
require_relative "../../script/golden/release_baseline"

# The shared "no difference" harness (slice-1a design, section 3.5): every
# scenario of script/core_invisibility_golden, run on this tree in a child
# process in each mode, against the golden file and against the plain mode
# on the same tree. The golden names the git ids of the source it was
# written from (script/core_invisibility_golden says how), so a core change
# that changes no record passes as it is, and one that does fails here.
module CoreInvisibilityHarness
  ROOT = File.expand_path("../..", __dir__)
  GOLDEN = File.join(ROOT, "spec/fixtures/core_invisibility_golden.json")
  # A method a slice adds to the four classes is a `smith_` name or one of
  # these public DSL macros. No slice adds a constant a host body can see,
  # overrides a name Object or Kernel has, or removes a method or constant,
  # but for the names 0.16.0 added to Smith::Workflow and the constants it
  # added to Smith::Agent (RETURNED_TO_0_15).
  DSL_MACROS = %w[provider_credentials].freeze
  # The private methods and constants 0.16.0 added to Smith::Workflow, and
  # the constants it added to Smith::Agent, each one a host's subclass could
  # replace or shadow, and where each went, so Workflow's surface is 0.15.0's
  # again and Agent's constants are. In the surface's order.
  RETURNED_TO_0_15 = {
    "Smith::ImageAttempt" => %w[check_image_agent! failed_paint held_paint image_refusals outcome_uncertain
                                paint_model painted painting_attempt painting_chat],
    "functions of Smith::PaintedAnswer" => %w[kept moderation_blocked? painted_completion refused_completion],
    "functions of Smith::Agent::ProviderFailureHandling" => %w[goes_again? step_may_retry? throttled?],
    "Smith::NestedItems" => %w[ended_refused execute_nested_items item_envelope item_shares items_environment
                               nested_item_outcome nested_items_of run_item_child run_nested_item
                               run_nested_item_child settle_item_envelope]
  }.flat_map { |home, names| names.map { ["- Smith::Workflow instance private #{_1}", home] } }.sort.to_h.merge(
    "- Smith::Workflow constants MODERATION_BLOCKED" => "Smith::PaintedAnswer, no longer included",
    "- Smith::Workflow constants NestedItemsExecution" => "Smith::NestedItems",
    **%w[ImageRequest PaintInput PaintedAnswer ProviderPaint].to_h do |name|
      ["- Smith::Agent constants #{name}", "Smith::#{name}"]
    end
  ).freeze
  # Paths whose every provider attempt a trial must observe.
  OBSERVED_PATHS = %w[parallel_branches fan_out nested_workflow optimize orchestrate image_answer nested_items
                      image_refusal_fallback repair_exhausted orchestrate_string_keys orchestrate_restored
                      image_answered_errors image_failures image_agents image_held image_retry_restored
                      items_painting items_outcomes items_budget items_durable].freeze

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
    # DSL macro, or one of the names 0.16.0 added to Smith::Workflow, gone.
    def allowed?(change)
      sign, _klass, table, *, name = change.split
      return RETURNED_TO_0_15.key?(change) if sign == "-"

      sign == "+" && %w[instance singleton].include?(table) &&
        (name.start_with?("smith_") || DSL_MACROS.include?(name))
    end

    def leaves(tree, path = [])
      return [[path, tree]] if tree.is_a?(Array)

      tree.flat_map { |key, value| leaves(value, [*path, key]) }
    end

    # A file written again from the ids it names, as compared with the one
    # committed: everything but the versions block, which another machine's
    # gems may change.
    def again_comparable(again, written) = again.merge("environment" => written["environment"])

    def git(*, repo: ROOT) = Open3.capture3("git", "-C", repo, *)

    def git_history? = git("rev-parse", "-q", "--verify", "HEAD").last.success?

    # Why the source a fixture names (the golden, or the release baseline)
    # cannot be read here, or nil when commits HEAD reaches hold every part.
    # Committed, its ids are in history; a full clone where HEAD does not
    # reach them is a fault (a part changed after the file was written, so
    # the file came from a tree never committed), not a reason to skip.
    def recorded_source_missing(document = golden, fixture = GOLDEN, repo: ROOT, label: "the golden")
      missing = unreachable(document["smith"].fetch("parts").values, repo:)
      return if missing.empty?
      return "a shallow clone lacks the history #{label}'s source is in" if shallow?(repo)
      if changed?(fixture, repo)
        return "#{label}'s source is this tree's uncommitted change; its ids are in history once committed"
      end

      raise "#{label} names parts this repository's history does not hold: #{missing.join(", ")}"
    end

    # The ids no commit HEAD reaches holds: an object `git write-tree` or
    # `git add` left behind is in the repository, not in its history.
    def unreachable(ids, repo: ROOT)
      ids - git("rev-list", "--objects", "HEAD", repo:).first.lines.map { _1.split.first }
    end

    def shallow?(repo = ROOT) = git("rev-parse", "--is-shallow-repository", repo:).first.strip == "true"

    def changed?(fixture = GOLDEN, repo = ROOT)
      paths = [*CoreInvisibility::GitSource::PARTS, fixture.delete_prefix("#{ROOT}/")]
      !git("status", "--porcelain", "--", *paths, repo:).first.empty?
    end
  end

  # The golden moves with every change that alters a record; the release
  # baseline does not (script/golden/release_baseline.rb), and holds the tree
  # to the last release on what a leak would show.
  module Release
    PATH = CoreInvisibility::ReleaseBaseline::PATH
    # The release the baseline comes from, and the commit its harness does
    # (0.16.0 predates the harness). Changed only at a release, when the
    # baseline is written again from the release's commit and CHANGES starts
    # empty.
    SOURCE = { "version" => "0.16.0", "source" => "release", "release" => "9f03162ef274c00fc6dbe67a3c55007185ee9407",
               "harness" => "a91fd457812ecca3e3ed7cec4075b7da9960490c" }.freeze
    # The scenarios slice 016 added (script/golden/scenarios/paint_failures.rb,
    # paint_agents.rb and item_paths.rb), each with the facts it measured.
    module Added
      SCENARIOS = [
        { "scenario" => "image_answered_errors",
          "new" => { "random_draws" => 27, "requests" => 9, "logs" => 0,
                     "counts" => { "Smith::Agent::Registry.fetch!" => 21, "RubyLLM::Context.new" => 9 },
                     "traces" => { ":deterministic_step" => 14, ":transition" => 14, ":provider_call" => 9,
                                   ":token_usage" => 2, ":cost" => 2 },
                     "events" => { "Smith::Events::StepCompleted" => 9, "Smith::Events::StepFailed" => 5 } },
          "why" => "added: a paint answered 500, 504, 401, 403, 404, 529 or 400, its fallback waiting",
          "slice" => "016 findings" },
        { "scenario" => "image_failures",
          "new" => { "random_draws" => 19, "requests" => 6, "logs" => 0,
                     "counts" => { "Smith::Agent::Registry.fetch!" => 15, "RubyLLM::Context.new" => 6 },
                     "traces" => { ":deterministic_step" => 10, ":transition" => 10, ":provider_call" => 6,
                                   ":token_usage" => 1, ":cost" => 1, ":output_rejected" => 1 },
                     "events" => { "Smith::Events::StepCompleted" => 5, "Smith::Events::StepFailed" => 5 } },
          "why" => "added: a paint throttled twice, lost, refused, answering no image, or kept by no store",
          "slice" => "016 findings" },
        { "scenario" => "image_agents",
          "new" => { "random_draws" => 11, "requests" => 2, "logs" => 0,
                     "counts" => { "Smith::Agent::Registry.fetch!" => 14, "RubyLLM::Context.new" => 2 },
                     "traces" => { ":deterministic_step" => 6, ":transition" => 8, ":provider_call" => 2,
                                   ":token_usage" => 2, ":cost" => 2 },
                     "events" => { "Smith::Events::StepCompleted" => 5, "Smith::Events::StepFailed" => 3 } },
          "why" => "added: image agents by inheritance; one with tools, streamed or batched, refused",
          "slice" => "016 findings" },
        { "scenario" => "image_held",
          "new" => { "random_draws" => 14, "requests" => 5, "logs" => 0,
                     "counts" => { "Smith::Agent::Registry.fetch!" => 15, "RubyLLM::Context.new" => 6 },
                     "traces" => { ":provider_call" => 6, ":token_usage" => 3, ":cost" => 3, ":transition" => 5,
                                   ":output_rejected" => 1 },
                     "events" => { "Smith::Events::StepCompleted" => 2, "Smith::Events::StepFailed" => 3 } },
          "why" => "added: paints held on the host's ledger: painted, throttled, refused, lost, not admitted",
          "slice" => "016 findings" },
        { "scenario" => "image_retry_restored",
          "new" => { "random_draws" => 6, "requests" => 3, "logs" => 0,
                     "counts" => { "Smith::Agent::Registry.fetch!" => 9, "RubyLLM::Context.new" => 3 },
                     "traces" => { ":provider_call" => 3, ":transition" => 4, ":token_usage" => 1, ":cost" => 1 },
                     "events" => { "Smith::Events::StepCompleted" => 1, "Smith::Events::StepFailed" => 1 } },
          "why" => "added: a throttled paint's durable retry restored and resumed; a server's error not retried",
          "slice" => "016 findings" },
        { "scenario" => "items_painting",
          "new" => { "random_draws" => 7, "requests" => 2, "logs" => 0,
                     "counts" => { "Smith::Agent::Registry.fetch!" => 6, "RubyLLM::Context.new" => 2 },
                     "traces" => { ":provider_call" => 2, ":token_usage" => 2, ":cost" => 2, ":transition" => 3 },
                     "events" => { "Smith::Events::StepCompleted" => 3 } },
          "why" => "added: items whose runs paint, within the run's budget", "slice" => "016 findings" },
        { "scenario" => "items_outcomes",
          "new" => { "random_draws" => 29, "requests" => 8, "logs" => 0,
                     "counts" => { "Smith::Agent::Registry.fetch!" => 24 },
                     "traces" => { ":provider_call" => 8, ":token_usage" => 7, ":cost" => 7, ":transition" => 14,
                                   ":output_rejected" => 2 },
                     "events" => { "Smith::Events::StepCompleted" => 8, "Smith::Events::StepFailed" => 6 } },
          "why" => "added: items refused (routed and raised) and failing; none, not an Array, over the limit",
          "slice" => "016 findings" },
        { "scenario" => "items_budget",
          "new" => { "random_draws" => 14, "requests" => 4, "logs" => 0,
                     "counts" => { "Smith::Agent::Registry.fetch!" => 12 },
                     "traces" => { ":provider_call" => 4, ":token_usage" => 4, ":cost" => 4, ":transition" => 6 },
                     "events" => { "Smith::Events::StepCompleted" => 5, "Smith::Events::StepFailed" => 1 } },
          "why" => "added: items within the run's budget, and items exceeding it", "slice" => "016 findings" },
        { "scenario" => "items_durable",
          "new" => { "random_draws" => 22, "requests" => 7, "logs" => 0,
                     "counts" => { "Smith::Agent::Registry.fetch!" => 21 },
                     "traces" => { ":provider_call" => 7, ":token_usage" => 6, ":cost" => 6, ":transition" => 13 },
                     "events" => { "Smith::Events::StepCompleted" => 9, "Smith::Events::StepFailed" => 1 } },
          "why" => "added: an items step's durable retry restored and resumed; items after a durable wait",
          "slice" => "016 findings" }
      ].freeze
    end

    # The scenarios the RubyLLM 2.x move's first slice added (script/golden/
    # scenarios/ruby_llm_requests.rb and ruby_llm_replies.rb): what the move
    # changes without an error, each with the facts it measured.
    module Pinned
      ONE_CALL = { "random_draws" => 3, "counts" => { "Smith::Agent::Registry.fetch!" => 3 }, "requests" => 1,
                   "traces" => { ":provider_call" => 1, ":token_usage" => 1, ":cost" => 1, ":transition" => 1 },
                   "events" => { "Smith::Events::StepCompleted" => 1 }, "logs" => 0 }.freeze
      SCENARIOS = [
        { "scenario" => "uncapped", "new" => ONE_CALL,
          "why" => "added: a step whose agent sets no output cap, held on the ledger at the cap it sends" },
        { "scenario" => "cached_instructions", "new" => ONE_CALL,
          "why" => "added: cached instructions and seed part, held as a cache write, settled with cache and thinking" },
        { "scenario" => "automatic_cache",
          "new" => { "random_draws" => 4, "counts" => { "Smith::Agent::Registry.fetch!" => 3 }, "requests" => 2,
                     "traces" => { ":tool_call" => 1, ":provider_call" => 1, ":token_usage" => 1, ":cost" => 1,
                                   ":transition" => 1 },
                     "events" => { "Smith::Events::StepCompleted" => 1 }, "logs" => 0 },
          "why" => "added: a tool loop asking for Anthropic's automatic cache, each round held on the ledger" },
        { "scenario" => "truncation_retry",
          "new" => { "random_draws" => 5, "counts" => { "Smith::Agent::Registry.fetch!" => 3 }, "requests" => 2,
                     "traces" => { ":provider_call" => 2, ":token_usage" => 2, ":cost" => 2, ":output_rejected" => 1,
                                   ":transition" => 1 },
                     "events" => { "Smith::Events::StepCompleted" => 1 }, "logs" => 0 },
          "why" => "added: a reply cut off at its cap, asked again with the larger one" },
        { "scenario" => "reasoning_cap", "new" => ONE_CALL,
          "why" => "added: an OpenAI model that reasons, its cap sent as max_completion_tokens" },
        { "scenario" => "streamed_limit_reached",
          "new" => { "random_draws" => 3,
                     "counts" => { "Smith::Agent::Registry.fetch!" => 3, "RubyLLM::Context.new" => 1 },
                     "requests" => 1,
                     "traces" => { ":provider_call" => 1, ":token_usage" => 1, ":cost" => 1, ":output_rejected" => 1,
                                   ":transition" => 1 },
                     "events" => { "Smith::Events::StepFailed" => 1 }, "logs" => 0 },
          "why" => "added: a streamed reply ending at its cap without a stop reason, read as limit reached" },
        { "scenario" => "paused_thinking",
          "new" => { "random_draws" => 5, "counts" => { "Smith::Agent::Registry.fetch!" => 6 }, "requests" => 2,
                     "traces" => { ":tool_call" => 1, ":provider_call" => 2, ":transition" => 3, ":token_usage" => 1,
                                   ":cost" => 1 },
                     "events" => { "Smith::Events::StepCompleted" => 1 }, "logs" => 0 },
          "why" => "added: a thinking tool loop paused for budget, continued with its thinking and tool call id" },
        { "scenario" => "spend_limit_refusal",
          "new" => { "random_draws" => 2, "counts" => { "Smith::Agent::Registry.fetch!" => 3 }, "requests" => 1,
                     "traces" => { ":provider_call" => 1, ":transition" => 1 },
                     "events" => { "Smith::Events::StepFailed" => 1 }, "logs" => 0 },
          "why" => "added: a spend cap sent as a rate limit, the step failing on RubyLLM's payment-required error" },
        { "scenario" => "dropped_fallback",
          "new" => { "random_draws" => 4, "counts" => { "Smith::Agent::Registry.fetch!" => 3 }, "requests" => 2,
                     "traces" => { ":provider_call" => 2, ":token_usage" => 1, ":cost" => 1, ":transition" => 1 },
                     "events" => { "Smith::Events::StepCompleted" => 1 }, "logs" => 0 },
          "why" => "added: a connection dropped once the request was sent, the fallback model answering" },
        { "scenario" => "memo_cached_replay",
          "new" => { "random_draws" => 4, "counts" => { "Smith::Agent::Registry.fetch!" => 6 }, "requests" => 1,
                     "traces" => { ":provider_call" => 1, ":token_usage" => 1, ":cost" => 1, ":transition" => 1 },
                     "events" => { "Smith::Events::StepCompleted" => 1 }, "logs" => 0 },
          "why" => "added: a memo replaying a kept reply that read and wrote the cache, nothing sent again" }
      ].map { _1.merge("slice" => "RubyLLM 2.x pins") }.freeze
    end

    # The names 0.16.0 gave every host class and where each went, as
    # allowances: the private methods (`instance`) or the constants (of one
    # class, when named).
    returned = lambda do |methods, klass = nil|
      CoreInvisibilityHarness::RETURNED_TO_0_15.filter_map do |change, home|
        next unless change.include?(" instance ") == methods
        next if klass && !change.include?(" #{klass} ")

        host = change.include?(" Smith::Agent ") ? "agent" : "workflow"
        { "surface" => change, "why" => "a name 0.16.0 gave every host #{host}, now #{home}",
          "slice" => "016 findings" }
      end
    end

    # Every way the tree differs from the release baseline, reviewed: a host
    # surface change ("+ <class> <table> <name>", which the harness's
    # `allowed?` must take), a scenario's facts ({fact => [release's,
    # tree's]}), or a scenario the baseline lacks, with the facts the slice
    # that added it measured, so they hold until a release's baseline has it.
    # Each says why and which slice; one the tree no longer shows fails too.
    CHANGES = [
      *returned.call(true),
      { "surface" => "+ Smith::Workflow singleton public provider_credentials",
        "why" => "the run credentials DSL macro (additions design 3.3), the one macro the harness allows",
        "slice" => "1c run credentials" },
      { "surface" => "+ Smith::Workflow singleton public smith_provider_credentials_scope_keys",
        "why" => "the declared scope keys' reader the design names, prefixed so no host name collides",
        "slice" => "1c run credentials" },
      *returned.call(false, "Smith::Workflow"),
      { "surface" => "+ Smith::Agent singleton public smith_prompt",
        "why" => "the named prompt an agent's instructions are, which the prompt seam reads (plan 5.2), prefixed",
        "slice" => "4 prompt seam" },
      *returned.call(false, "Smith::Agent"),
      { "scenario" => "orchestrate", "random_draws" => [11, 9],
        "why" => "an orchestrate worker's execution_id is named by its position, no longer drawn (two workers)",
        "slice" => "memo restore" },
      { "scenario" => "orchestrate_string_keys",
        "new" => { "random_draws" => 9, "counts" => { "Smith::Agent::Registry.fetch!" => 2 }, "requests" => 4,
                   "traces" => { ":provider_call" => 4, ":token_usage" => 4, ":cost" => 4, ":transition" => 1 },
                   "events" => { "Smith::Events::StepCompleted" => 1 }, "logs" => 0 },
        "why" => "added: orchestrate with String keys throughout and no after_completion",
        "slice" => "memo restore" },
      { "scenario" => "orchestrate_restored",
        "new" => { "random_draws" => 20, "counts" => { "Smith::Agent::Registry.fetch!" => 4 }, "requests" => 6,
                   "traces" => { ":provider_call" => 9, ":token_usage" => 9, ":cost" => 9, ":transition" => 1 },
                   "events" => { "Smith::Events::StepCompleted" => 1 }, "logs" => 0 },
        "why" => "added: three rounds, killed once round 2's decision is kept, restored; 6 requests, 0.16.0 sent 7",
        "slice" => "memo restore" },
      *Added::SCENARIOS,
      *Pinned::SCENARIOS
    ].freeze

    class << self
      def baseline = @baseline ||= JSON.parse(File.read(PATH))

      # How a plain run differs from the baseline, as CHANGES lists it: each
      # host surface change, each scenario whose facts differ, each the
      # baseline lacks, and each the run lacks.
      def differences(baseline, run)
        was = baseline["scenarios"]
        scenarios = run["scenarios"].filter_map { |name, records| scenario(name, records, was[name]) }
        surface(baseline, run) + scenarios + (was.keys - run["scenarios"].keys).map { gone(_1) }
      end

      def surface(baseline, run)
        changes = CoreInvisibilityHarness.surface_changes(baseline["host_surface"], run["host_surface"])
        changes.map { { "surface" => _1 } }
      end

      def scenario(name, records, was)
        now = CoreInvisibility::ReleaseBaseline.facts(records)
        return { "scenario" => name, "new" => now } unless was

        changed = (now.keys | was.keys).reject { now[_1] == was[_1] }.to_h { [_1, [was[_1], now[_1]]] }
        { "scenario" => name, **changed } unless changed.empty?
      end

      def gone(name) = { "scenario" => name, "gone" => true }

      # Why the release tag cannot be checked here (a clone without tags),
      # or nil when it names the baseline's release; raises when it names
      # another commit.
      def tag_unchecked(baseline, repo: ROOT)
        version, release = baseline["smith"].values_at("version", "release")
        tag = CoreInvisibilityHarness.git("rev-parse", "-q", "--verify", "refs/tags/v#{version}^{commit}", repo:)
                                     .first.strip
        return "the v#{version} tag is not in this clone (git fetch --tags), so its commit is not checked" if tag.empty?
        return if tag == release

        raise "v#{version} names #{tag}, but the release baseline was written from #{release}"
      end
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

  it "has a golden file from a commit or the staged index, its parts named by git id, over forty-four scenarios" do
    # The parts that decide what the harness records, by their git ids, and
    # the commit their tree was built on; the golden file is none of them.
    source = golden["smith"]
    parts = CoreInvisibility::GitSource::PARTS
    expect(source.keys).to eq(%w[version source built_on parts])
    expect(source.values.first(3)).to match(["0.16.0", /\A(index|commit)\z/, /\A\h{40}\z/])
    expect(source["parts"].keys).to eq(parts)
    expect(source["parts"].values).to all(match(/\A\h{40}\z/))
    fixture = CoreInvisibilityHarness::GOLDEN.delete_prefix("#{CoreInvisibilityHarness::ROOT}/")
    expect(parts.select { fixture == _1 || fixture.start_with?("#{_1}/") }).to eq([])
    expect(golden["process"]["observer_installed"]).to be(false)
    expect(golden["scenarios"].keys).to eq(
      %w[serial_output_schema tool_loop parallel_branches fan_out route nested_workflow inline_call_child optimize
         orchestrate streamed batch fallback_after_overload output_repair budget_ledger memo_replay budget_pause
         durable_await durable_retry image_answer nested_items image_unkept image_refusal_fallback repair_exhausted
         orchestrate_string_keys orchestrate_restored image_answered_errors image_failures image_agents image_held
         image_retry_restored items_painting items_outcomes items_budget items_durable uncapped cached_instructions
         automatic_cache truncation_retry reasoning_cap streamed_limit_reached paused_thinking spend_limit_refusal
         dropped_fallback memo_cached_replay]
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
    expect(failed.keys).to include("image_unkept", "repair_exhausted", "image_answered_errors", "items_outcomes")
    expect(seen.sum { _1["counts"].values.sum }).to be_positive
    # The errors scenarios mean to raise (the memo replays' kills). Any
    # other is a crash, which a regenerated golden must not hold.
    errored = golden["scenarios"].reject { |_name, scenario| scenario["errors"].empty? }
    expect(errored.transform_values { |scenario| scenario["errors"].map { _1["class"] } })
      .to eq("memo_replay" => ["CoreInvisibility::Hosts::Killed"],
             "orchestrate_restored" => ["CoreInvisibility::Hosts::Killed"],
             "memo_cached_replay" => ["CoreInvisibility::Hosts::Killed"])
  end

  it "has a release baseline from Smith 0.16.0, its parts named by git id, holding what a leak would show" do
    baseline = CoreInvisibilityHarness::Release.baseline
    smith = baseline["smith"]
    expect(baseline.keys).to eq(%w[format smith environment process host_surface scenarios])
    expect(baseline["format"]).to eq(CoreInvisibility::ReleaseBaseline::FORMAT)
    expect(smith.except("parts")).to eq(CoreInvisibilityHarness::Release::SOURCE)
    expect(smith["parts"].keys).to eq(CoreInvisibility::GitSource::PARTS)
    expect(smith["parts"].values).to all(match(/\A\h{40}\z/))
    # 0.16.0 has no eval seam.
    expect(baseline["process"]).to eq("evals_defined" => false, "attempt_observation" => false,
                                      "observer_installed" => false, "empty_attribution_fields" => {})
    expect(baseline["host_surface"].keys).to eq(%w[Smith::Workflow Smith::Agent Smith::Context Smith::Tool])
    expect(baseline["scenarios"].values.map(&:keys).uniq).to eq([CoreInvisibility::ReleaseBaseline::FACTS])
    # Scenarios are only added, at the end.
    expect(golden["scenarios"].keys.first(baseline["scenarios"].length)).to eq(baseline["scenarios"].keys)
    CoreInvisibilityHarness::Release::CHANGES.each do |change|
      expect([change["why"], change["slice"]]).to all(match(/\S/)), change.inspect
    end
  end

  describe "a golden file written from git" do
    let(:source) { CoreInvisibility::GitSource }
    let(:script) { File.join(CoreInvisibilityHarness::ROOT, "script/core_invisibility_golden") }

    before { skip "needs this repository's git history" unless CoreInvisibilityHarness.git_history? }

    def unbundled(*command) = Bundler.with_unbundled_env { Open3.capture3(*command) }

    # The script runs in this bundle, as a contributor runs it, vendored or
    # not; it hands its golden bundle the gems it sees.
    def scripted(*arguments) = Open3.capture3(RbConfig.ruby, script, *arguments)

    def git(*args) = CoreInvisibilityHarness.git(*args).first.strip

    # Its install takes Bundler's lock in its own gem home, never the shared
    # one another bundle install on the machine may hold; every installed
    # gem stays readable through GEM_PATH.
    it "installs the golden bundle with a gem home and settings of its own" do
      handed = nil
      allow(source).to receive(:system) { |env, *| handed = env }
      Dir.mktmpdir { source.bundle!(_1) }

      expect(handed["GEM_HOME"]).not_to eq(Gem.dir)
      expect(handed["BUNDLE_APP_CONFIG"]).to eq(handed["GEM_HOME"])
      expect(handed["GEM_PATH"].split(File::PATH_SEPARATOR)).to include(Gem.dir)
    end

    # Anyone can extract the parts by their ids and write the golden again.
    # Another machine's gems may differ (the versions block); nothing else.
    it "comes from the parts it names: extracted by their git ids, they write the same golden again" do
      reason = CoreInvisibilityHarness.recorded_source_missing
      skip reason if reason
      Dir.mktmpdir do |dir|
        path = File.join(dir, "again.json")
        _out, err, status = scripted("--write", path, "--source-of", CoreInvisibilityHarness::GOLDEN)
        expect([status.success?, err]).to eq([true, ""])
        written = File.read(path)
        again = JSON.parse(written)

        harness = CoreInvisibilityHarness
        expect(harness.text(harness.again_comparable(again, golden))).to eq(harness.text(golden))
        expect(written).to eq(File.read(harness::GOLDEN)) if again["environment"] == golden["environment"]
      end
    end

    it "compares a file written again in every block but the versions" do
      harness = CoreInvisibilityHarness
      same = ->(again) { harness.text(harness.again_comparable(again, golden)) == harness.text(golden) }
      changed = %w[format smith process host_surface scenarios].to_h do |block|
        [block, same.call(golden.merge(block => { "changed" => true }))]
      end

      expect(changed).to eq(%w[format smith process host_surface scenarios].to_h { [_1, false] })
      expect(same.call(golden.merge("environment" => { "ruby" => "0" }))).to be(true)
    end

    # Written from the release's commit, only at a release; anyone can
    # write it again from the ids it names, and no golden regeneration does.
    it "comes from the release's commit, and its parts write the same release baseline again" do
      harness = CoreInvisibilityHarness
      baseline = CoreInvisibilityHarness::Release.baseline
      reason = harness.recorded_source_missing(baseline, CoreInvisibilityHarness::Release::PATH,
                                               label: "the release baseline")
      skip reason if reason
      smith = baseline["smith"]
      expect(CoreInvisibility::ReleaseBaseline.from_commit(smith["release"], harness: smith["harness"])).to eq(smith)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "again.json")
        _out, err, status = scripted("--write-release", path, "--source-of", CoreInvisibilityHarness::Release::PATH)
        expect([status.success?, err]).to eq([true, ""])
        written = File.read(path)
        again = JSON.parse(written)

        expect(harness.text(harness.again_comparable(again, baseline))).to eq(harness.text(baseline))
        same_gems = again["environment"] == baseline["environment"]
        expect(written).to eq(File.read(CoreInvisibilityHarness::Release::PATH)) if same_gems
      end
    end

    it "names the commit its release tag names, or says why the tag cannot be checked" do
      reason = CoreInvisibilityHarness::Release.tag_unchecked(CoreInvisibilityHarness::Release.baseline)
      skip reason if reason
    end

    it "takes a commit's parts, or the staged index's and never an unstaged edit, by their git ids" do
      head = git("rev-parse", "HEAD")
      named = source::PARTS.to_h { [_1, git("rev-parse", "HEAD:#{_1}")] }
      expect(source.from_commit("HEAD")).to eq("source" => "commit", "built_on" => head, "parts" => named)
      Dir.mktmpdir do |dir|
        clone = cloned(dir)
        File.write(File.join(clone, "lib/smith/staged_part.rb"), "# staged\n")
        system("git", "-C", clone, "add", "lib/smith/staged_part.rb", exception: true)
        File.write(File.join(clone, "lib/smith/version.rb"), "# not staged\n", mode: "a")

        index = source.from_index(repo: clone)
        lib = index["parts"]["lib"]
        listed = Open3.capture3("git", "-C", clone, "ls-tree", "-r", lib).first
        expect([index["source"], index["built_on"]]).to eq(["index", head])
        expect(index["parts"].except("lib")).to eq(named.except("lib"))
        unstaged = "blob #{git("rev-parse", "HEAD:lib/smith/version.rb")}\tsmith/version.rb\n"
        expect(listed).to include("\tsmith/staged_part.rb\n", unstaged)
      end
    end

    # A clone of HEAD sharing this repository's objects; what it stores
    # stays in it.
    def cloned(dir)
      File.join(dir, "clone").tap do |clone|
        quiet = %w[-c advice.detachedHead=false]
        system("git", *quiet, "clone", "-q", "--shared", CoreInvisibilityHarness::ROOT, clone, exception: true)
      end
    end

    # A clone with this tree's parts staged, so the harness as it is now
    # writes and refuses without a write to this repository's objects.
    def staged_clone(dir)
      root = CoreInvisibilityHarness::ROOT
      clone = cloned(dir)
      source::PARTS.each do |part|
        FileUtils.rm_r(File.join(clone, part))
        FileUtils.cp_r(File.join(root, part), File.join(clone, part))
      end
      system("git", "-C", clone, "add", "-A", "--", *source::PARTS, exception: true)
      clone
    end

    it "writes from this tree's harness, and refuses a part changed, added to or taken from, or code in its Gemfile" do
      Dir.mktmpdir do |dir|
        clone = staged_clone(dir)
        staged = source.from_index(repo: clone)
        folder = File.join(dir, "folder").tap { Dir.mkdir(_1) }
        source.extract(staged, folder, repo: clone)
        source.bundle!(folder, repo: clone)
        tried = lambda do |name, file = nil, text = nil|
          kept = file && File.exist?(file) && File.binread(file)
          text ? File.write(file, text) : file && File.delete(file)
          unbundled(*source.writer(folder, File.join(dir, "#{name}.json"), repo: clone)).tap do
            kept ? File.binwrite(file, kept) : file && File.delete(file)
          end
        end
        version = File.join(folder, "lib/smith/version.rb")
        gemspec = File.join(folder, "smith-agents.gemspec")
        written = tried.call("written")
        outcomes = [
          tried.call("changed", version, "#{File.read(version)}# changed\n"),
          tried.call("gemspec", gemspec, "#{File.read(gemspec)}# changed\n"),
          tried.call("added", File.join(folder, "lib/smith/extra.rb"), "# added\n"),
          tried.call("gone", File.join(folder, "lib/smith/canonical_json.rb")),
          tried.call("planted", File.join(folder, source::GEMFILE), "#{source::GEMFILE_TEXT}ENV[\"PLANTED\"] = \"1\"\n")
        ]

        expect([written[2].success?, written[1]]).to eq([true, ""])
        # The golden bundle resolves the versions the suite's Gemfile.lock holds.
        if File.file?(File.join(CoreInvisibilityHarness::ROOT, "Gemfile.lock"))
          locked = File.read(File.join(folder, "#{source::GEMFILE}.lock"))
          %w[faraday json].each { expect(locked).to include("\n    #{_1} (#{Gem.loaded_specs[_1].version})") }
        end
        expect(JSON.parse(File.read(File.join(dir, "written.json")))["smith"].except("version")).to eq(staged)
        outcomes.each { |(_out, err, status)| expect([status.success?, err]).to match([false, /not other/]) }
        expect(Dir.children(dir).grep(/\.json\z/)).to eq(["written.json"])
      end
    end

    it "refuses an unknown id, an unknown commit and a working tree" do
      recorded = source.from_commit("HEAD")
      unknown = Tempfile.create(%w[unknown .json]) do |file|
        parts = recorded["parts"].merge("lib" => "0" * 40)
        file.write(JSON.generate("smith" => { "version" => "0.16.0", **recorded, "parts" => parts }))
        file.flush
        scripted("--write", File::NULL, "--source-of", file.path)
      end
      expect([unknown[2].success?, unknown[1]]).to match([false, /git cat-file/])
      _out, err, status = scripted("--write", File::NULL, "--commit", "no-such-commit")
      expect([status.success?, err]).to match([false, /git rev-parse/])
      _out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(CoreInvisibilityHarness::ROOT, "lib"), script,
                                         "--write", File::NULL)
      expect([status.success?, err]).to match([false, /not tree/])
    end
  end

  # A repository of its own holding this tree's parts and golden in one
  # commit, so the examples below need neither this repository's history
  # nor a full clone of it.
  def committed_repo(dir)
    root = CoreInvisibilityHarness::ROOT
    repo = File.join(dir, "repo")
    [*CoreInvisibility::GitSource::PARTS, CoreInvisibilityHarness::GOLDEN.delete_prefix("#{root}/")].each do |part|
      FileUtils.mkdir_p(File.dirname(File.join(repo, part)))
      FileUtils.cp_r(File.join(root, part), File.join(repo, part))
    end
    system("git", "-c", "init.defaultBranch=main", "init", "-q", repo, exception: true)
    committing(repo, "add", "-A")
    committing(repo, "commit", "-qm", "parts")
    repo
  end

  def committing(repo, *args)
    system("git", "-C", repo, "-c", "user.name=spec", "-c", "user.email=spec@example.invalid", "-c",
           "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args, exception: true)
  end

  # A golden written from the index and a part edited before the commit:
  # the ids are objects in the author's repository, but no commit holds
  # them, and a fresh clone has none. The author's run must fail as that
  # clone's does.
  it "holds every id it names in HEAD's history, and fails a full repository whose HEAD does not reach them" do
    source = CoreInvisibility::GitSource
    harness = CoreInvisibilityHarness
    Dir.mktmpdir do |dir|
      repo = committed_repo(dir)
      part = File.join(repo, "lib/smith/version.rb")
      fixture = File.join(repo, harness::GOLDEN.delete_prefix("#{harness::ROOT}/"))
      File.write(part, "#{File.read(part)}# staged\n")
      committing(repo, "add", "-A")
      staged = golden.merge("smith" => golden["smith"].merge(source.from_index(repo:)))
      File.write(fixture, JSON.generate(staged))
      lib = staged["smith"]["parts"]["lib"]
      missing = -> { harness.recorded_source_missing(staged, fixture, repo:) }

      expect(missing.call).to match(/uncommitted change/)
      File.write(part, "#{File.read(part)}# edited again\n")
      committing(repo, "commit", "-qam", "stale")
      expect(Open3.capture3("git", "-C", repo, "cat-file", "-e", lib).last.success?).to be(true)
      expect { missing.call }.to raise_error(/history does not hold: #{lib}/)
      held = golden.merge("smith" => golden["smith"].merge(source.from_commit("HEAD", repo:)))
      expect(harness.recorded_source_missing(held, fixture, repo:)).to be_nil
    end
  end

  # The release tag is checked when the clone has it: absent, the example
  # says so; naming another commit, it fails.
  it "checks the release tag where it is, says why where it is not, and fails where it names another commit" do
    release = CoreInvisibilityHarness::Release
    Dir.mktmpdir do |dir|
      repo = committed_repo(dir)
      head = CoreInvisibilityHarness.git("rev-parse", "HEAD", repo:).first.strip
      baseline = { "smith" => { "version" => "0.16.0", "release" => head } }

      expect(release.tag_unchecked(baseline, repo:)).to eq(
        "the v0.16.0 tag is not in this clone (git fetch --tags), so its commit is not checked"
      )
      committing(repo, "tag", "-a", "v0.16.0", "-m", "release")
      expect(release.tag_unchecked(baseline, repo:)).to be_nil
      other = baseline.merge("smith" => baseline["smith"].merge("release" => "0" * 40))
      expect { release.tag_unchecked(other, repo:) }.to raise_error(/v0.16.0 names #{head}/)
    end
  end

  it "matches the golden file byte for byte in a child process without the observer, which sees no seam in use" do
    plain = CoreInvisibilityHarness.run("plain")

    expect(plain["smith"]["source"]).to eq("tree")
    expect(plain["process"]).to eq("evals_defined" => false, "attempt_observation" => true,
                                   "observer_installed" => false, "empty_attribution_fields" => {})
    expect(plain["host_surface"]).to eq(golden["host_surface"])
    expect_golden_scenarios(plain)
  end

  # Against the release baseline, which no golden regeneration writes.
  it "adds no name a host's Workflow, Agent, Context or Tool subclass could collide with, and removes none" do
    harness = CoreInvisibilityHarness
    changes = harness.surface_changes(CoreInvisibilityHarness::Release.baseline["host_surface"],
                                      harness.run("plain")["host_surface"])
    listed = CoreInvisibilityHarness::Release::CHANGES.filter_map { _1["surface"] }

    expect(changes).to eq(listed)
    expect(listed.reject { harness.allowed?(_1) }).to eq([])
  end

  # Only the names 0.16.0 added to Smith::Workflow may leave it; any other
  # name gone from any class is refused.
  it "allows a name to go only where it is one 0.16.0 added to Smith::Workflow, or a constant it added to Agent" do
    harness = CoreInvisibilityHarness
    gone = ["- Smith::Workflow instance private execute_step", "- Smith::Workflow instance public run!",
            "- Smith::Agent singleton public image_request", "- Smith::Agent constants Lifecycle",
            "- Smith::Workflow constants Execution", "- Smith::Context instance private painted",
            "- Smith::Tool constants PaintInput"]

    returned = harness::RETURNED_TO_0_15.keys
    expect([returned.length, returned.count { _1.include?(" instance private ") }]).to eq([33, 27])
    expect(returned.count { _1.start_with?("- Smith::Agent constants ") }).to eq(4)
    expect(returned).to all(start_with("- Smith::Workflow ").or(start_with("- Smith::Agent constants ")))
    expect(returned.select { harness.allowed?(_1) }).to eq(returned)
    expect(gone.select { harness.allowed?(_1) }).to eq([])
  end

  it "differs from the release baseline only as listed: draws, lookups, requests, traces, events and log lines" do
    release = CoreInvisibilityHarness::Release
    differences = release.differences(release.baseline, CoreInvisibilityHarness.run("plain"))

    expect(differences).to eq(release::CHANGES.map { _1.except("why", "slice") })
  end

  it "names each fact of a scenario that differs from the release baseline, a name added, and a scenario gone" do
    release = CoreInvisibilityHarness::Release
    run = CoreInvisibilityHarness.run("plain")
    tools = run["scenarios"]["tool_loop"]
    leaked = tools.merge("random_draws" => tools["random_draws"] + 1,
                         "counts" => tools["counts"].merge("Smith::Agent::Registry.capture_bindings!" => 1),
                         "requests" => [*tools["requests"], tools["requests"].last],
                         "traces" => [*tools["traces"], tools["traces"].last],
                         "events" => [*tools["events"], ["Smith::Events::Planted", {}]],
                         "logs" => tools["logs"].map { |lines| lines.merge(":smith" => [*lines[":smith"], "planted"]) })
    surface = JSON.parse(JSON.generate(run["host_surface"]))
    surface["Smith::Workflow"]["constants"] << "PLANTED"
    planted = run.merge("host_surface" => surface,
                        "scenarios" => run["scenarios"].merge("tool_loop" => leaked).except("batch"))
    differences = release.differences(release.baseline, planted) - release.differences(release.baseline, run)

    facts = %w[random_draws counts requests traces events logs]
    expect(differences.map { _1.except("scenario").keys }).to eq([%w[surface], facts, %w[gone]])
    expect(differences.first).to eq("surface" => "+ Smith::Workflow constants PLANTED")
    expect(differences.last).to eq("scenario" => "batch", "gone" => true)
  end

  # The seam's invisibility was proven once against a Smith without it
  # (eb14417 against 6bd0609); on this tree it is the plain mode's records.
  it "keeps the seam invisible on this tree: observer and trial modes give the plain mode's records, sink by sink" do
    harness = CoreInvisibilityHarness
    plain = harness.run("plain")
    %w[observer trial].each do |mode|
      run = harness.run(mode)
      expect(run["scenarios"].keys).to eq(plain["scenarios"].keys)
      expect(run["host_surface"]).to eq(plain["host_surface"]), mode
      plain["scenarios"].each do |name, records|
        records.each do |sink, value|
          expect(harness.text(run["scenarios"][name][sink])).to eq(harness.text(value)), "#{mode} #{name} #{sink}"
        end
      end
    end
  end

  # Slice 4: with an agent in the process declaring a named prompt, and a
  # prompt registry that refuses every call, a run whose agents declare
  # none is the run it was: nothing pinned, stamped, saved or asked.
  it "gives the golden's records with the prompt seam in use beside agents that declare no named prompt" do
    prompted = CoreInvisibilityHarness.run("prompted")

    expect(prompted["prompts_declared"]).to be(true)
    expect(prompted["host_surface"]).to eq(golden["host_surface"])
    expect_golden_scenarios(prompted)
  end

  # Slice 1c: every path on a run's own credentials, and nothing sent without
  # them under the fail-closed mode, each on this tree against its plain mode.
  describe "run credentials on every path" do
    let(:harness) { CoreInvisibilityHarness }
    let(:run_key) { "sk-golden-run-key-0123456789abcdef" }

    # The records with the run's saved scope (an empty one: no scope keys),
    # the scope its batch requests are queued with, and its key taken out,
    # as the plain mode has none of them, and a provider error's causes,
    # which its scrubbed copy has none of (additions design 3.6): the causes
    # recorded after it, and its trace's cause class. A refusal for want of
    # credit (spend_limit_refusal) carries Smith's fixed text in a
    # credentialed run, the provider's in a plain one (design 3.5): both read
    # as one.
    def without_credentials(value)
      case value
      when Hash
        kept = without_provider_causes(value.except(":provider_credentials_scope", ":credentials_scope"))
        kept.transform_values { without_credentials(_1) }
      when Array then value.map { without_credentials(_1) }
      when String
        value.gsub('"provider_credentials_scope":{},', "").gsub(out_of_credit, "OUT OF CREDIT")
             .sub(/\A(Bearer )?(test|#{run_key})\z/) { "#{Regexp.last_match(1)}KEY" }
      else value
      end
    end

    def out_of_credit
      Regexp.union("You have reached your API usage limits: your organization has crossed its monthly API usage " \
                   "threshold.", /(anthropic|the provider) reports the account is out of credit \(HTTP 402\)/)
    end

    def provider_error?(name) = name.to_s.start_with?("RubyLLM::")

    def without_provider_causes(record)
      record = record.except(":error_cause_class") if provider_error?(record[":error_class"])
      causes = record["causes"]
      return record unless causes.is_a?(Array)

      kept = provider_error?(record["class"]) ? 0 : causes.index { provider_error?(_1["class"]) }&.succ
      kept ? record.merge("causes" => causes.first(kept)) : record
    end

    it "gives the plain mode's records on every path but the one context a credentialed run builds" do
      plain = harness.run("plain")
      credentialed = harness.run("credentialed")
      expect(credentialed["scenarios"].keys).to eq(plain["scenarios"].keys)
      expect(credentialed["host_surface"]).to eq(plain["host_surface"])

      plain["scenarios"].each do |name, records|
        run = credentialed["scenarios"][name]
        records.except("counts").each do |sink, value|
          expect(harness.text(without_credentials(run[sink]))).to eq(harness.text(without_credentials(value))),
                                                                  "#{name} #{sink}"
        end
        built = run["counts"].to_h { |label, count| [label, count - records["counts"][label]] }.reject { _2.zero? }
        expect(built.keys).to eq(%w[RubyLLM.context RubyLLM::Context.new]), name
        expect(built.values.uniq.length).to eq(1), name
        expect(run["requests"].map { |request| request[2].values_at("x-api-key", "authorization").compact.sole })
          .to all(end_with(run_key)), name
        expect(run["states"].map { _1[":provider_credentials_scope"] }.uniq).to eq([{}]), name
        expect(run["batches"].to_a.map { _1[":credentials_scope"] }).to all(eq({})), name
        # The canary: the run's key, or any 12-character run of it, only on the wire.
        windows = (0..(run_key.length - 12)).map { run_key[_1, 12] }
        held = run.except("requests").select { |_sink, value| windows.any? { harness.text(value).include?(_1) } }
        expect(held.keys).to eq([]), name
      end
    end

    it "observes each provider attempt once on every credentialed path, as in a trial" do
      credentialed = harness.run("credentialed")

      credentialed["scenarios"].each do |name, scenario|
        traced = harness.provider_calls(scenario)
        traced = traced.reject { _1[":workflow"] == "GoldenCallChildWorkflow" } if name == "inline_call_child"
        observed = credentialed["observations"].fetch(name).map { _1["attempt_id"] }
        expect(observed).to eq(traced.map { _1[":attempt_id"] }), name
      end
    end

    it "fails closed on every path: no request, ledger call, provider call or usage, each a missing credential" do
      closed = harness.run("fail_closed")
      expect(closed["scenarios"].keys).to eq(harness.run("plain")["scenarios"].keys)

      closed["scenarios"].each do |name, scenario|
        expect(%w[requests ledger memo batches].to_h { [_1, scenario[_1]] }).to eq(
          "requests" => [], "ledger" => [], "memo" => [], "batches" => []
        ), name
        expect([harness.provider_calls(scenario), scenario["usage_entries"].flatten]).to eq([[], []]), name
        expect(harness.text(scenario)).to include("Smith::ProviderCredentialsMissing"), name
      end
    end
  end

  it "reports how two golden files differ, scenario by scenario" do
    scenarios = golden["scenarios"]
    # A namespace changed for another of the same length, as a fix that
    # names one rather than drawing it changes a golden.
    child = scenarios["inline_call_child"]
    key = ":execution_namespace"
    renamed = child["states"].map { |state| state.merge(key => state[key].reverse) }
    changed = golden.merge("process" => golden["process"].merge("attempt_observation" => "changed"),
                           "scenarios" => scenarios.except("batch").merge(
                             "streamed" => scenarios["streamed"].merge("requests" => [], "usage_entries" => []),
                             "inline_call_child" => child.merge("states" => renamed), "extra" => scenarios["batch"]
                           ))
    Dir.mktmpdir do |dir|
      paths = [golden, changed].each_with_index.map do |doc, at|
        File.join(dir, "#{at}.json").tap { File.write(_1, JSON.generate(doc)) }
      end
      script = File.join(CoreInvisibilityHarness::ROOT, "script/core_invisibility_golden")
      out, err, status = Open3.capture3(RbConfig.ruby, script, "--diff", *paths)

      expect([status.success?, err]).to eq([true, ""])
      lines = out.lines(chomp: true)
      expect(lines.first(5)).to eq(["smith: same", "environment: same", "process: attempt_observation",
                                    "host_surface: same", "serial_output_schema: same"])
      expect(lines).to include("streamed: requests, usage_entries", "inline_call_child: states",
                               "batch: only in the first", "extra: only in the second")
      expect(lines.length).to eq(4 + scenarios.length + 1)
    end
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
