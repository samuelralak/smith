# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "smith/evals"

# Suites (slice-1a design 4.5, 8.5): the DSL, the manifest it writes, the
# suite version and the measure digest, against the published code suite.
RSpec.describe Smith::Evals::Suite do
  examples = File.expand_path("../../../docs/evals/examples", __dir__)
  published = JSON.parse(File.read(File.join(examples, "suite/support.ticket_triage.manifest.json")))
  version = "sha256:c23bed10efb170e9afeaea625a87c4811393c4a9089b402b56682ede4a6e0f8a"
  measure = "sha256:41f4d1454e4caed2a75622ad9dcdb2b1dcbb2ea59518562cfd53d6292a573565"
  sample_ids = "sha256:9e9a450bb65f50cb9f8a75e076f8d09bd6044d30e4a030d7a306d28558939ac8"

  around do |example|
    Dir.mktmpdir("smith-evals-suite") do |dir|
      FileUtils.mkdir_p(File.join(dir, "evals"))
      FileUtils.cp_r(File.join(examples, "dataset/support-tickets"), File.join(dir, "evals/support_tickets"))
      root = Smith::Evals.config.dataset_root
      Smith::Evals.config.dataset_root = "evals"
      Dir.chdir(dir) { example.run }
    ensure
      Smith::Evals.config.dataset_root = root
    end
  end

  before { stub_const("TicketTriage", Class.new(Smith::Workflow)) }

  let(:mapping) { :input.to_proc }

  # The published code suite, as a Ruby class; the priority scorer's
  # settings and the target can be changed.
  def triage_suite(priority: { version: 2, also: [:mean] }, target: 0.8, &extra)
    Class.new(described_class) do
      suite_name "support.ticket_triage"
      dataset "support_tickets"
      subject workflow: TicketTriage, input: ->(sample) { { ticket: sample.input[:text] } }, keep: %i[triage]
      trials 3, reduce: :majority
      scorer(:category, version: 1) { |_sample, _trial| Smith::Evals::Score.pass }
      scorer(:priority, **priority) { |_sample, _trial| Smith::Evals::Score.pass }
      gate :category_floor, scorer: :category, at_least: target
      budget max_cost_nanos: 250_000_000
      class_eval(&extra) if extra
    end
  end

  def bare_suite(&body)
    Class.new(described_class) do
      suite_name "support.ticket_triage"
      class_eval(&body)
    end
  end

  describe "the published code suite" do
    it "writes its manifest and version (sha256:c23bed10...)" do
      suite = triage_suite

      expect(suite.manifest).to eq(published)
      expect(suite.version).to eq(version)
      expect(suite.manifest).to be_frozen
    end

    it "selects the 37 dev samples and gives the records' measure digest (sha256:41f4d145...)" do
      selection = triage_suite.selection
      dev = JSON.parse(File.read("evals/support_tickets/manifest.json")).dig("split_assignment", "dev")

      expect(selection.samples.map(&:id)).to eq(dev)
      expect([selection.sample_ids_digest, selection.measure_digest]).to eq([sample_ids, measure])
      expect(triage_suite.measure_digest).to eq(measure)
    end

    it "gives the same manifest, version and measure digest in child processes under other locales and time zones" do
      script = <<~RUBY
        require "smith/evals"
        class TicketTriage < Smith::Workflow; end
        Smith::Evals.config.dataset_root = "evals"
        suite = Class.new(Smith::Evals::Suite) do
          suite_name "support.ticket_triage"
          dataset "support_tickets"
          subject workflow: TicketTriage, input: :input.to_proc, keep: %i[triage]
          trials 3, reduce: :majority
          scorer(:category, version: 1) { Smith::Evals::Score.pass }
          scorer(:priority, version: 2, also: [:mean]) { Smith::Evals::Score.pass }
          gate :category_floor, scorer: :category, at_least: 0.8
          budget max_cost_nanos: 250_000_000
        end
        print Smith::CanonicalJSON.generate("manifest" => suite.manifest, "measure" => suite.measure_digest)
      RUBY
      lib = File.expand_path("../../../lib", __dir__)
      outputs = [{ "LC_ALL" => "C", "LANG" => "C", "TZ" => "Asia/Kathmandu" },
                 { "LC_ALL" => "tr_TR.UTF-8", "LANG" => "tr_TR.UTF-8", "TZ" => "America/Adak" }].map do |env|
        stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-I", lib, "-e", script)
        raise stderr unless status.success?

        stdout
      end

      expect(outputs.uniq).to eq([Smith::CanonicalJSON.generate("manifest" => published, "measure" => measure)])
    end
  end

  describe "the version and the measure digest" do
    it "leave out the budget and the dataset's location" do
      base = triage_suite
      moved = triage_suite do
        dataset File.expand_path("evals/support_tickets")
        budget max_cost_nanos: 1
      end

      expect(moved.manifest["dataset"]["source"]).not_to eq(base.manifest["dataset"]["source"])
      expect([moved.version, moved.measure_digest]).to eq([base.version, base.measure_digest])
      expect(triage_suite { budget max_cost_nanos: nil }.manifest["budget"]).to be_nil
    end

    it "change when a scorer is added, or one's version, scale, reducers or failure rule change" do
      base = triage_suite
      changed = [
        triage_suite { scorer(:extra, version: 1) { Smith::Evals::Score.pass } },
        triage_suite(priority: { version: 3, also: [:mean] }),
        triage_suite(priority: { version: 2, also: [] }),
        triage_suite(priority: { version: 2, also: [:mean], reduce: :any }),
        triage_suite(priority: { version: 2, also: [:mean], on_subject_failure: :score }),
        triage_suite(priority: { version: 2, scale: :continuous })
      ]

      expect(changed.map(&:version).uniq.size).to eq(changed.size)
      expect(changed.map(&:version)).not_to include(base.version)
      expect(changed.map(&:measure_digest)).not_to include(base.measure_digest)
    end

    it "track a target in the version but not in the measure digest (8.5)" do
      base = triage_suite
      moved = triage_suite(target: 0.9)

      expect(moved.version).not_to eq(base.version)
      expect(moved.measure_digest).to eq(base.measure_digest)
    end

    # Design 6.3: a listed class makes a failure an error, out of the rate,
    # instead of a subject failure counted in it.
    it "write the infrastructure errors as sorted class names, in the version and the measure digest" do
      base = triage_suite
      listed = triage_suite { infrastructure_errors IOError, Errno::ECONNRESET }
      reordered = triage_suite { infrastructure_errors [Errno::ECONNRESET], IOError }

      expect(listed.manifest["trials"])
        .to eq("per_sample" => 3, "error_retries" => 2, "infrastructure_errors" => %w[Errno::ECONNRESET IOError],
               "reduce" => "majority")
      expect(listed.manifest["trials"].keys).to eq(%w[per_sample error_retries infrastructure_errors reduce])
      expect(base.manifest["trials"]["infrastructure_errors"]).to eq([])
      expect([reordered.version, reordered.measure_digest]).to eq([listed.version, listed.measure_digest])
      expect(listed.version).not_to eq(base.version)
      expect(listed.measure_digest).not_to eq(base.measure_digest)
    end

    it "write keep sorted, so its order changes neither digest" do
      mapping = self.mapping
      sorted = triage_suite { subject workflow: TicketTriage, input: mapping, keep: %i[triage notes] }
      reversed = triage_suite { subject workflow: TicketTriage, input: mapping, keep: %w[notes triage] }

      expect(sorted.manifest["subject"]["keep"]).to eq(%w[notes triage])
      expect([reversed.version, reversed.measure_digest]).to eq([sorted.version, sorted.measure_digest])
    end

    it "track the subject's identity in the version but not in the measure digest" do
      stub_const("TicketTriageV2", Class.new(Smith::Workflow))
      mapping = self.mapping
      base = triage_suite
      other = triage_suite { subject workflow: TicketTriageV2, input: mapping, keep: %i[triage] }
      remapped = triage_suite { subject workflow: TicketTriage, input: mapping, keep: %i[triage], version: 2 }

      expect(other.version).not_to eq(base.version)
      expect(other.measure_digest).to eq(base.measure_digest)
      expect(remapped.measure_digest).not_to eq(base.measure_digest)
    end
  end

  describe "the DSL" do
    it "names a suite from its class, underscored, with dots for ::" do
      stub_const("Support::TicketTriageHTTPSuite", Class.new(described_class))

      expect(Support::TicketTriageHTTPSuite.suite_name).to eq("support.ticket_triage_http_suite")
    end

    it "fills the defaults the design states, and writes every one in the manifest" do
      mapping = self.mapping
      suite = Class.new(described_class) do
        suite_name "demo"
        dataset "support_tickets"
        subject workflow: TicketTriage, input: mapping
        scorer(:quality, version: 1, scale: :continuous) { Smith::Evals::Score.value(1) }
        scorer(:category, version: 1) { Smith::Evals::Score.pass }
      end
      manifest = suite.manifest

      expect(manifest.slice("selection", "trials", "statistics", "recording", "gates", "budget", "labels", "judges"))
        .to eq("selection" => { "split" => "dev", "narrow" => nil },
               "trials" => { "per_sample" => 3, "error_retries" => 2, "infrastructure_errors" => [],
                             "reduce" => "majority" },
               "statistics" => { "level" => 0.95, "bootstrap_resamples" => 2000, "small_sample_threshold" => 30 },
               "recording" => { "content" => true }, "gates" => [], "budget" => nil,
               "labels" => { "accept" => "any" }, "judges" => [])
      expect(manifest["subject"])
        .to eq("kind" => "workflow", "workflow" => "TicketTriage", "keep" => [], "until" => nil, "version" => 1)
      expect(manifest["scorers"].map { _1.values_at("reduce", "also", "on_subject_failure") })
        .to eq([["mean", [], "fail"], ["majority", [], "fail"]])
      expect([suite.concurrency, suite.error_retries, suite.infrastructure_errors]).to eq([1, 2, []])
    end

    it "takes a class scorer, its settings from the class and its reducers from the suite" do
      tone = Class.new(Smith::Evals::Scorer) do
        scorer_name :tone
        version 4
        on_subject_failure :score
        def score(*) = Smith::Evals::Score.pass
      end
      suite = triage_suite { scorer tone, reduce: :any, also: [{ pass_at: 2 }] }
      category = Class.new(tone) { scorer_name :category }

      expect(suite.manifest["scorers"].last)
        .to eq("name" => "tone", "kind" => "code", "version" => 4, "scale" => "binary", "reduce" => "any",
               "also" => ["pass_at_2"], "on_subject_failure" => "score")
      expect(suite.scorers.map(&:name)).to eq(%w[category priority tone])
      expect(triage_suite { scorer tone.new }.manifest["scorers"].last["name"]).to eq("tone")
      expect { triage_suite { scorer category }.manifest }
        .to raise_error(Smith::Evals::SuiteInvalid, %r{/scorers/2/name: category is used by another scorer})
    end

    it "narrows the split by ids or tags, as sorted data, and refuses an id the split does not hold" do
      by_ids = triage_suite { narrow ids: %w[t-0004 t-0002] }
      by_tags = triage_suite { narrow tags_any: %w[refund login] }

      expect(by_ids.manifest["selection"]["narrow"]).to eq("ids" => %w[t-0002 t-0004])
      expect(by_ids.selection.samples.map(&:id)).to eq(%w[t-0002 t-0004])
      expect(by_tags.manifest["selection"]["narrow"]).to eq("tags_any" => %w[login refund])
      expect(by_tags.selection.samples.map(&:id)).to eq(%w[t-0008 t-0018 t-0025 t-0042])
      expect(by_ids.measure_digest).not_to eq(by_tags.measure_digest)
      expect { triage_suite { narrow ids: %w[t-0003] }.selection }
        .to raise_error(Smith::Evals::SuiteInvalid, %r{/selection/narrow/ids/0: t-0003 is not in the dev split})
    end

    # Vectors an independent implementation computed from the design alone:
    # the digests take the narrowed samples, and until is measured.
    it "gives the independent vectors for a narrowed selection and for until" do
      mapping = self.mapping
      narrowed = triage_suite { narrow ids: %w[t-0004 t-0002] }.selection
      stopped = triage_suite { subject workflow: TicketTriage, input: mapping, keep: %i[triage], until: :triaged }

      expect([narrowed.sample_ids_digest, narrowed.measure_digest])
        .to eq(%w[sha256:02eb99eda1ee7910f6186876f01ac35f5f9656ddad6ed6948ac0d64b1cfe47ea
                  sha256:b6a4ea199239d2ceddb34eb77584e2349c17891cdcb5b3d1244ff9dbe30e885c])
      expect(stopped.manifest["subject"]["until"]).to eq("triaged")
      expect(stopped.measure_digest).to eq("sha256:6bb49b22f8b391b56e74c9103da181c6e15a98c6537bce2b4acdb4567b5f8a3b")
    end

    it "refuses a dataset whose version is not the one it pins" do
      pinned = triage_suite { dataset "support_tickets", version: "sha256:#{"0" * 64}" }

      expect(pinned.manifest["dataset"]["pinned_version"]).to eq("sha256:#{"0" * 64}")
      expect { pinned.selection }.to raise_error(Smith::Evals::DatasetChanged, /pinned/)
    end

    it "reads a host source in the run's scope, recording no location for it" do
      folder = Smith::Evals::FileDataset.new("evals/support_tickets")
      scopes = []
      source = Object.new
      source.define_singleton_method(:manifest) do |scope:|
        scopes << scope
        folder.manifest
      end
      source.define_singleton_method(:each_sample) do |scope:, &block|
        scopes << scope
        folder.each_sample(&block)
      end
      suite = triage_suite { dataset source }

      expect(suite.manifest(scope: { tenant: "ten_0193" })["dataset"])
        .to eq(published["dataset"].merge("source" => nil))
      expect(suite.version).to eq(version)
      expect(suite.selection(scope: { tenant: "ten_0193" }).measure_digest).to eq(measure)
      expect(scopes.uniq).to eq([{ "tenant" => "ten_0193" }, {}])
    end

    it "lets a subclass add to its parent's declarations without changing the parent" do
      parent = triage_suite
      child = Class.new(parent) { scorer(:tone, version: 1) { Smith::Evals::Score.pass } }

      expect(child.manifest["scorers"].map { _1["name"] }).to eq(%w[category priority tone])
      expect(parent.manifest["scorers"].map { _1["name"] }).to eq(%w[category priority])
    end
  end

  describe "refusals" do
    def problems(suite)
      suite.manifest
      []
    rescue Smith::Evals::SuiteInvalid => e
      e.problems
    end

    it "refuses each case of design 4.5 with its problem line" do
      mapping = self.mapping
      cases = {
        "no dataset" => [bare_suite do
          subject workflow: TicketTriage, input: mapping
          scorer(:category, version: 1) { nil }
        end, '/dataset: is required: dataset "folder" or a source'],
        "no subject" => [bare_suite do
          dataset "support_tickets"
          scorer(:category, version: 1) { nil }
        end, "/subject: is required: subject workflow:, input:"],
        "no scorer" => [bare_suite do
          dataset "support_tickets"
          subject workflow: TicketTriage, input: mapping
        end, "/scorers: a suite needs at least one scorer"],
        "a duplicate scorer name" => [triage_suite { scorer(:category, version: 1) { nil } },
                                      "/scorers/2/name: category is used by another scorer"],
        "a reducer that does not fit the scale" => [
          triage_suite { scorer(:quality, version: 1, scale: :continuous, reduce: :majority) { nil } },
          "/scorers/2/reduce: majority does not fit a continuous scorer"
        ],
        "pass_at above the trials" => [triage_suite { scorer(:tries, version: 1, also: [{ pass_at: 4 }]) { nil } },
                                       "/scorers/2/also/0: pass_at_4 needs at least 4 trials per sample, not 3"],
        "keep past 64 keys" => [
          triage_suite { subject workflow: TicketTriage, input: mapping, keep: (1..65).map { :"k#{_1}" } },
          "/subject/keep: names at most 64 keys, not 65"
        ],
        "trials past 100" => [triage_suite { trials 101 }, "/trials/per_sample: is an Integer from 1 to 100, not 101"],
        "trials below 1" => [triage_suite { trials 0 }, "/trials/per_sample: is an Integer from 1 to 100, not 0"],
        "error_retries past 10" => [triage_suite { error_retries 11 },
                                    "/trials/error_retries: is an Integer from 0 to 10, not 11"],
        "concurrency below 1" => [triage_suite { concurrency 0 }, "concurrency: is an Integer of at least 1, not 0"],
        "an unknown split" => [triage_suite { split :test },
                               "/selection/split: is dev, holdout or calibration, not test"]
      }

      cases.each do |name, (suite, line)|
        expect(problems(suite)).to eq([line]), name
      end
    end

    it "names every problem at once, and the suite in its message" do
      suite = triage_suite do
        trials 0
        error_retries(-1)
        split :test
      end

      expect { suite.manifest }
        .to raise_error(Smith::Evals::SuiteInvalid, /\Asuite support.ticket_triage is invalid: /) { |error|
          expect(error.problems.size).to eq(3)
        }
    end

    it "refuses other malformed declarations, each by its path" do
      mapping = self.mapping
      empty = Class.new(Smith::Evals::Scorer) do
        scorer_name :empty
        version 1
      end
      cases = {
        triage_suite { subject workflow: Class.new, input: mapping } =>
          "/subject/workflow: is a named class (a Smith::Workflow subclass, unless a host driver runs it)",
        triage_suite { subject workflow: TicketTriage, input: "text" } => "/subject/input: responds to call(sample)",
        triage_suite { subject workflow: TicketTriage, input: mapping, version: 0 } =>
          "/subject/version: is an Integer from 1 to 2**53 - 1",
        triage_suite { subject workflow: TicketTriage, input: mapping, keep: %i[a a] } =>
          "/subject/keep: names a key twice",
        triage_suite { scorer(:Bad, version: 1) { nil } } => "/scorers/2/name: matches ^[a-z][a-z0-9_]{0,63}$",
        triage_suite { scorer(:noversion) { nil } } =>
          "/scorers/2/version: is required: an Integer of at least 1 you bump when the scorer's meaning changes",
        triage_suite { scorer(:twice, version: 1, also: [:majority]) { nil } } =>
          "/scorers/2/also: repeats the headline reducer majority",
        triage_suite { scorer(empty) } => "/scorers/2: must define score(sample, trial)",
        triage_suite { scorer("not a scorer") } =>
          "/scorers/2: is a name and a block, a Smith::Evals::Scorer class or a scorer",
        triage_suite { statistics level: 1.0 } => "/statistics/level: is a number above 0 and at most 0.999999999",
        triage_suite { statistics bootstrap_resamples: 50 } =>
          "/statistics/bootstrap_resamples: is an Integer from 100 to 100000",
        triage_suite { gate :floor, scorer: :tone, at_least: 0.8 } => "/gates/1/scorer: names no scorer of this suite",
        triage_suite { gate :category_floor, scorer: :category, at_least: 1.2 } =>
          "/gates/1/id: category_floor is used by another gate",
        triage_suite { labels accept: :everyone } => "/labels/accept: is any or human_only",
        triage_suite { infrastructure_errors "PG::ConnectionBad" } =>
          "/trials/infrastructure_errors/0: is a named Exception class",
        triage_suite { infrastructure_errors IOError, Class.new(StandardError) } =>
          "/trials/infrastructure_errors/1: is a named Exception class",
        triage_suite { infrastructure_errors IOError, IOError } => "/trials/infrastructure_errors: names a class twice",
        triage_suite { infrastructure_errors(*Array.new(65) { IOError }) } =>
          "/trials/infrastructure_errors: names at most 64 classes",
        triage_suite { dataset 42 } =>
          "/dataset: is a folder or a source answering manifest(scope:) and each_sample(scope:)",
        triage_suite { dataset "support_tickets", version: "md5:x" } =>
          "/dataset/pinned_version: is a digest: sha256: and 64 lowercase hex digits"
      }

      cases.each do |suite, line|
        expect(problems(suite)).to include(line)
      end
    end

    # Values the checks once passed and canonical JSON then refused: each is
    # now a problem line, never another error.
    it "refuses integers past 2**53 - 1 and text that is not UTF-8, each by its path" do
      mapping = self.mapping
      cases = {
        triage_suite { subject workflow: TicketTriage, input: mapping, version: 2**60 } =>
          "/subject/version: is an Integer from 1 to 2**53 - 1",
        triage_suite { scorer(:big, version: 2**60) { nil } } =>
          "/scorers/2/version: is an Integer from 1 to 2**53 - 1",
        triage_suite { statistics small_sample_threshold: 2**60 } =>
          "/statistics/small_sample_threshold: is an Integer from 1 to 2**53 - 1",
        triage_suite { subject workflow: TicketTriage, input: mapping, keep: ["\xFF".b] } =>
          "/subject/keep: is an Array of state keys",
        triage_suite { subject workflow: TicketTriage, input: mapping, until: "\xFF".b } =>
          "/subject/until: is nil or a state name",
        triage_suite { narrow tags_any: ["\xFF".b] } => "/selection/narrow/tags_any: is a list of distinct names",
        triage_suite { narrow ids: ["t\u0001"] } => "/selection/narrow/ids: is a list of distinct sample ids",
        triage_suite { narrow ids: [:"t-0002", "t-0002"] } => "/selection/narrow/ids: is a list of distinct sample ids",
        triage_suite { suite_name "\xFF" } =>
          "/name: is a name (^[a-z][a-z0-9_.-]{0,127}$); an anonymous suite needs suite_name",
        triage_suite { gate "\xFF", scorer: :category, at_least: 0.5 } =>
          "/gates/1/id: is a code (^[a-z][a-z0-9_]{0,63}$)",
        triage_suite { scorer("\xFF", version: 1) { nil } } => "/scorers/2/name: matches ^[a-z][a-z0-9_]{0,63}$"
      }

      cases.each do |suite, line|
        expect(problems(suite)).to include(line)
      end
    end

    it "refuses version: or scale: beside a scorer instance, as beside a class" do
      tone = Class.new(Smith::Evals::Scorer) do
        scorer_name :tone
        version 4
        def score(*) = Smith::Evals::Score.pass
      end

      expect(problems(triage_suite { scorer tone.new, version: 7 }))
        .to eq(["/scorers/2: a Scorer declares its own version and scale"])
      expect(problems(triage_suite { scorer tone.new, scale: :continuous }))
        .to eq(["/scorers/2: a Scorer declares its own version and scale"])
      expect(problems(triage_suite { scorer tone, version: 7 }))
        .to eq(["/scorers/2: a Scorer declares its own version and scale"])
    end

    # Design 6.3: a listed class makes a failure an error, out of the rate;
    # one that covers the subject's own failures would leave only successes.
    it "refuses an infrastructure error broad enough to count the subject's own failures, naming it" do
      broad = [Exception, StandardError, Smith::Error, ScriptError, Smith::AgentError, Smith::OutputFailure,
               Smith::OutputInvalid, Smith::OutputRefused, Smith::BudgetExceeded, Smith::WorkflowError,
               Smith::ToolPolicyDenied, Smith::ProviderPermanentFailure]

      broad.each do |klass|
        expect(problems(triage_suite { infrastructure_errors IOError, klass }))
          .to eq(["/trials/infrastructure_errors/1: #{klass.name} is too broad: it would count the subject's own " \
                  "failures as infrastructure"]), klass.name
      end
      expect(problems(triage_suite { infrastructure_errors IOError, Smith::PersistenceIOError, Errno::ECONNRESET }))
        .to eq([])
    end

    it "names a refused scorer once, never again for a gate on it" do
      tone = Class.new(Smith::Evals::Scorer) do
        scorer_name :tone
        version 4
        def score(*) = Smith::Evals::Score.pass
      end
      suite = triage_suite do
        scorer tone.new, version: 7
        gate :tone_floor, scorer: :tone, at_least: 0.5
      end

      expect(problems(suite)).to eq(["/scorers/2: a Scorer declares its own version and scale"])
      expect(problems(triage_suite { gate :tone_floor, scorer: :tone, at_least: 0.5 }))
        .to eq(["/gates/1/scorer: names no scorer of this suite"])
    end

    it "collects a subject's missing or unknown settings as problems, never raising while the class is read" do
      mapping = self.mapping

      expect(problems(triage_suite { subject workflow: TicketTriage }))
        .to eq(["/subject/input: responds to call(sample)"])
      expect(problems(triage_suite { subject input: mapping }))
        .to eq(["/subject/workflow: is a named class (a Smith::Workflow subclass, unless a host driver runs it)"])
      expect(problems(triage_suite { subject workflow: TicketTriage, input: mapping, inputs: 1 }))
        .to eq(["/subject: unknown setting inputs"])
    end

    it "refuses a holdout or calibration suite with SplitNotAllowed until slice 2" do
      %i[holdout calibration].each do |split|
        expect { triage_suite { split split }.manifest }.to raise_error(Smith::Evals::SplitNotAllowed, /#{split}/)
      end
    end
  end
end
