# frozen_string_literal: true

require "json"
require "open3"
require "smith/evals"

# Every id and digest of slice-1a design 8.1 to 8.6, against the vectors the
# reference generator computed for the contract examples
# (spec/fixtures/evals/identity_reference.json, copied from their headers and
# trial lines), and byte for byte across processes, locales and time zones.
RSpec.describe Smith::Evals::Identity do
  let(:reference) do
    JSON.parse(File.read(File.expand_path("../../fixtures/evals/identity_reference.json", __dir__)))
  end
  let(:records) { reference.fetch("records") }
  let(:dev_ids) do
    manifest = File.expand_path("../../../docs/evals/examples/dataset/support-tickets/manifest.json", __dir__)
    JSON.parse(File.read(manifest)).dig("split_assignment", "dev")
  end

  def run_id_for(record)
    described_class.eval_run_id(key: record["idempotency_key"], scope: record["scope"], suite: record["suite_name"],
                                variant: record.dig("variant", "digest"))
  end

  it "reproduces every example record's eval run id, from its key, scope, suite name and variant" do
    expect(records.size).to eq(7)
    expect(records.map { run_id_for(_1) }).to eq(records.map { _1["eval_run_id"] })
  end

  it "reproduces every trial id of every example record" do
    pairs = records.flat_map do |record|
      record["trials"].map do |sample_id, index, trial_id|
        [described_class.trial_id(eval_run_id: record["eval_run_id"], sample_id:, index:), trial_id]
      end
    end

    expect(pairs.size).to eq(693)
    expect(pairs.map(&:first)).to eq(pairs.map(&:last))
  end

  it "reproduces the sample ids digest, in whatever order the ids come" do
    expect(described_class.sample_ids_digest(dev_ids)).to eq(records.first["sample_ids_digest"])
    expect(described_class.sample_ids_digest(dev_ids.reverse)).to eq(records.first["sample_ids_digest"])
    expect(records.map { _1["sample_ids_digest"] }.uniq)
      .to eq(["sha256:9e9a450bb65f50cb9f8a75e076f8d09bd6044d30e4a030d7a306d28558939ac8"])
  end

  it "reproduces every example record's plan digest" do
    digests = records.map do |record|
      described_class.plan_digest(suite: record["suite_version"], dataset: record["dataset_version"],
                                  samples: record["sample_ids_digest"], split: record["split"],
                                  trials_per_sample: record["trials_per_sample"], candidate: record["candidate"],
                                  variant: record.dig("variant", "digest"))
    end

    expect(digests).to eq(records.map { _1["plan_digest"] })
  end

  it "reproduces the suite versions and measure digests of the code suite and the model comparison's data suite" do
    versions = records.map { described_class.suite_version(_1["suite_manifest"]) }
    measures = records.map do |record|
      described_class.measure_digest(record["suite_manifest"], dataset: record["dataset_version"],
                                                               samples: record["sample_ids_digest"])
    end

    expect(versions).to eq(records.map { _1["suite_version"] })
    expect(measures).to eq(records.map { _1["measure_digest"] })
    expect(versions.uniq.map { _1[0, 15] }.sort).to eq(%w[sha256:36d12700 sha256:c23bed10])
    expect(measures.uniq.map { _1[0, 15] }.sort).to eq(%w[sha256:330b75c3 sha256:41f4d145])
  end

  it "reproduces each variant's digest and the group id" do
    linked = records.select { _1["variant"] }

    expect(linked.map { described_class.variant_digest(_1.dig("variant", "llm")) })
      .to eq(linked.map { _1.dig("variant", "digest") })
    expect(described_class.group_id(key: reference["group_key"], scope: linked.first["scope"],
                                    suite: linked.first["suite_name"]))
      .to eq(linked.first.dig("group", "id"))
  end

  it "frames each id as design 8.6 states, keeping 32 hex digits" do
    scope = { "tenant" => "ten_0193" }
    run = described_class.eval_run_id(key: "k", scope:, suite: "s")
    trial = described_class.trial_id(eval_run_id: run, sample_id: "t-1", index: 0)

    expect(run).to eq("er_#{framed("smith.evals.eval_run/1", key: "k", scope:, suite: "s")}")
    expect(trial).to eq("tr_#{framed("smith.evals.trial/1", eval_run: run, index: 0, sample: "t-1")}")
    expect(described_class.trial_id(eval_run_id: run, sample_id: "t-1", index: 0, candidate: "cd_#{"0" * 32}"))
      .to eq("tr_#{framed("smith.evals.trial/1", candidate: "cd_#{"0" * 32}", eval_run: run, index: 0, sample: "t-1")}")
    expect(described_class.scope_digest(scope)).to eq(Smith::Scope.digest(scope))
  end

  it "frames the sample ids digest and gives the plan digest a format field, as design 8.1 states" do
    hash = "sha256:#{"a" * 64}"
    plan = { "format" => "smith.evals.plan/1", "candidate" => nil, "dataset" => hash, "samples" => hash,
             "split" => "dev", "suite" => hash, "trials_per_sample" => 3, "variant" => nil }

    expect(described_class.sample_ids_digest(%w[b a]))
      .to eq("sha256:#{Digest::SHA256.hexdigest(%(smith.evals.sample_ids/1\n["a","b"]))}")
    expect(described_class.plan_digest(suite: hash, dataset: hash, samples: hash, split: "dev", trials_per_sample: 3))
      .to eq("sha256:#{Digest::SHA256.hexdigest(Smith::CanonicalJSON.generate(plan))}")
  end

  def framed(frame, **value)
    Digest::SHA256.hexdigest("#{frame}\n#{Smith::CanonicalJSON.generate(value)}")[0, 32]
  end

  it "draws a random eval run id when no key is given" do
    ids = Array.new(3) { described_class.eval_run_id(key: nil, scope: {}, suite: "s") }

    expect(ids).to all(match(/\Aer_[0-9a-f]{32}\z/))
    expect(ids.uniq.size).to eq(3)
  end

  it "takes a scope with Symbol keys as its String form, and refuses one that is not a scope" do
    expect(described_class.eval_run_id(key: "k", scope: { tenant: "t" }, suite: "s"))
      .to eq(described_class.eval_run_id(key: "k", scope: { "tenant" => "t" }, suite: "s"))
    expect { described_class.eval_run_id(key: "k", scope: { tenant: 1 }, suite: "s") }
      .to raise_error(Smith::ScopeInvalid)
  end

  it "refuses an id part that is not of its kind" do
    expect { described_class.eval_run_id(key: "", scope: {}, suite: "s") }.to raise_error(ArgumentError, /key/)
    expect { described_class.eval_run_id(key: "k" * 257, scope: {}, suite: "s") }.to raise_error(ArgumentError, /key/)
    expect { described_class.eval_run_id(key: "k", scope: {}, suite: "Bad Name") }
      .to raise_error(ArgumentError, /suite/)
    expect { described_class.eval_run_id(key: "k", scope: {}, suite: "s", variant: "md5:1") }
      .to raise_error(ArgumentError, /variant/)
    expect { described_class.trial_id(eval_run_id: "er_1", sample_id: "t", index: 0) }
      .to raise_error(ArgumentError, /eval run id/)
    expect { described_class.trial_id(eval_run_id: "er_#{"0" * 32}", sample_id: "t", index: -1) }
      .to raise_error(ArgumentError, /index/)
    expect { described_class.trial_id(eval_run_id: "er_#{"0" * 32}", sample_id: "a\nb", index: 0) }
      .to raise_error(ArgumentError, /sample id/)
    expect { described_class.sample_ids_digest(%w[a a]) }.to raise_error(ArgumentError, /twice/)
  end

  it "gives the same bytes in child processes under other locales and time zones" do
    # ASCII only, with escapes, so a C locale reads the script as written.
    script = <<~'RUBY'
      require "smith/evals"
      I = Smith::Evals::Identity
      scope = { "tenant" => "t\u00e9n_\u00fc", "project" => "prj" }
      run = I.eval_run_id(key: "nightly-\u00e9-\u{1F600}", scope:, suite: "support.ticket_triage")
      ids = ["t-\u{FF5E}", "t-\u{1F600}", "t-a", "T-0001"]
      print Smith::CanonicalJSON.generate(
        "run" => run, "group" => I.group_id(key: "g", scope:, suite: "s"),
        "trials" => ids.map { I.trial_id(eval_run_id: run, sample_id: _1, index: 2) },
        "samples" => I.sample_ids_digest(ids), "scope" => I.scope_digest(scope),
        "variant" => I.variant_digest("provider" => "anthropic", "model" => "m", "settings" => { "temperature" => 0.7 },
                                      "fallbacks" => [])
      )
    RUBY
    outputs = [{ "LC_ALL" => "C", "LANG" => "C", "TZ" => "Pacific/Kiritimati" },
               { "LC_ALL" => "tr_TR.UTF-8", "LANG" => "tr_TR.UTF-8", "TZ" => "America/St_Johns" }].map do |env|
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__),
                                              "-e", script)
      raise stderr unless status.success?

      stdout
    end

    expect(outputs.uniq.size).to eq(1)
    ids = ["t-\u{FF5E}", "t-\u{1F600}", "t-a", "T-0001"]
    expect(JSON.parse(outputs.first)["samples"]).to eq(described_class.sample_ids_digest(ids))
  end

  it "sorts ids by UTF-16 code units, so a character past U+FFFF sorts before U+FF5E" do
    expect(described_class.utf16_sort(["t-\u{FF5E}", "t-\u{1F600}", "t-a"])).to eq(["t-a", "t-\u{1F600}", "t-\u{FF5E}"])
  end

  # An independent implementation's vector: UTF-8 byte order would put
  # U+FF5E before U+1F600.
  it "sorts the sample ids digest's ids by UTF-16 code units" do
    expect(described_class.sample_ids_digest(["\u{FF5E}", "\u{1F600}", "a"]))
      .to eq("sha256:27f3b97f2776ce1a06f6a3239f2a34e27ddb447d30b406ecf3ac627192b7420e")
  end

  it "takes the infrastructure errors into the suite version and the measure digest, and needs them" do
    manifest = records.first["suite_manifest"]
    listed = manifest.merge("trials" => manifest["trials"].merge("infrastructure_errors" => ["PG::ConnectionBad"]))
    dataset, samples = records.first.values_at("dataset_version", "sample_ids_digest")
    measure = ->(m) { described_class.measure_digest(m, dataset:, samples:) }

    expect(described_class.suite_version(listed)).not_to eq(described_class.suite_version(manifest))
    expect(measure.call(listed)).not_to eq(measure.call(manifest))
    expect { measure.call(manifest.merge("trials" => manifest["trials"].except("infrastructure_errors"))) }
      .to raise_error(ArgumentError, /suite manifest/)
  end
end
