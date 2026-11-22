# frozen_string_literal: true

require "json"
require "smith/evals/statistics"

RSpec.describe Smith::Evals::Statistics::Formulas do
  reference = JSON.parse(File.read(File.expand_path("../../../fixtures/evals/statistics_reference.json", __dir__)))
  # Closed forms (Wilson, estimators, Holm, sizes, the design effect): 1e-12 absolute (design 7.0).
  closed = 1e-12

  def table(row) = row.slice("a", "b", "c", "d").transform_keys(&:to_sym)

  it "matches statsmodels' Wilson interval in every fixture case" do
    reference["wilson_95"].each do |successes, total, lower, upper|
      result = described_class.wilson(p: successes.fdiv(total), n: total, level: 0.95)
      expect(result).to match([be_within(closed).of(lower), be_within(closed).of(upper)]), "#{successes} of #{total}"
    end
    expect(described_class.wilson(p: 0.5, n: 0, level: 0.95)).to eq([nil, nil])
  end

  it "matches the beta posterior on sample-level fractions" do
    row = reference["beta_posterior_fractions"]
    result = described_class.beta_posterior(successes: row["s"], n: row["n"], level: 0.95)

    expect(result).to match([be_within(closed).of(row["lower"]), be_within(closed).of(row["upper"])])
  end

  it "matches the t interval on a mean of 32 values" do
    row = reference["t_interval_mean"]
    result = described_class.t_interval(mean: row["mean"], sd: row["sd"], n: row["values"].size, level: 0.95)

    expect(result).to match([be_within(closed).of(row["lower"]), be_within(closed).of(row["upper"])])
  end

  it "matches Korn and Graubard's design effect in every fixture case" do
    reference["design_effect_wilson"].each do |row|
      design_effect, clusters, applies = described_class.design_effect(row["values"], row["clusters"])

      expect(design_effect).to be_within(closed).of(row["design_effect"])
      expect([clusters, applies]).to eq([row["clusters"].uniq.size, true])
      next unless row["lower"]

      expect(row["values"].size / design_effect).to be_within(closed).of(row["n_effective"])
      result = described_class.wilson(p: row["values"].sum.fdiv(row["values"].size), n: row["n_effective"], level: 0.95)
      expect(result).to match([be_within(closed).of(row["lower"]), be_within(closed).of(row["upper"])])
    end
  end

  it "clamps the design effect at 1, so clustering only widens" do
    # One cluster holds a pass and a fail: the cluster-robust variance is below
    # the independent one (a ratio of 0.9), so the design effect is 1.
    values = [1, 0, 1, 1, 1, 1, 0, 0, 0, 0]
    keys = ["a", "a", *("b".."i")]

    expect(described_class.design_effect(values, keys)).to eq([1.0, 9, true])
    expect(described_class.design_effect([1, 0, 1], %w[a b c])).to eq([1.0, 3, false])
  end

  it "reads one cluster holding every value as one independent unit: a design effect of n" do
    expect(described_class.design_effect([1, 0, 1], %w[a a a])).to eq([3.0, 1, true])
    expect(described_class.design_effect([0.1, 0.1], %w[a a])).to eq([2.0, 1, true])
    expect(described_class.design_effect([1], %w[a])).to eq([1.0, 1, false])
  end

  it "gives equal values a design effect of exactly 1, though their float mean is not exact" do
    expect(described_class.design_effect([0.1, 0.1, 0.1], %w[a a b])).to eq([1.0, 2, true])
    expect(described_class.design_effect(Array.new(100, 1.0 / 3), Array.new(100) { |index| "k#{index / 2}" }))
      .to eq([1.0, 50, true])
  end

  it "matches the seeded cluster bootstrap exactly, and SciPy's percentile bootstrap within 0.02" do
    row = reference["bootstrap_splitmix_pass_at_2"]
    values = row["samples"].map { |sample| described_class.pass_at(n: 3, c: sample["trials"].count(true), k: 2) }
    keys = row["samples"].map { |sample| "c:#{sample["cluster"]}" }
    result = described_class.cluster_bootstrap(values:, keys:, resamples: 2_000, seed: row["seed"].to_i(16),
                                               level: 0.95)
    expect(result).to eq([row["lower"], row["upper"]])

    plain = reference["bootstrap_percentile_mean"]
    keys = plain["data"].each_index.map { |index| "s:#{index}" }
    result = described_class.cluster_bootstrap(values: plain["data"], keys:, resamples: plain["n_resamples"], seed: 7,
                                               level: 0.95)
    expect(result).to match([be_within(0.02).of(plain["lower"]), be_within(0.02).of(plain["upper"])])
  end

  it "takes type 7 percentiles, as NumPy does" do
    expect(described_class.percentile([1, 2, 3, 4], 0.25)).to eq(1.75)
    expect(described_class.percentile([4, 1, 3, 2], 0.5)).to eq(2.5)
    expect(described_class.percentile([5], 0.9)).to eq(5)
    expect(described_class.percentile([], 0.5)).to be_nil
    expect { described_class.percentile([1], 1.5) }.to raise_error(ArgumentError)
  end

  it "computes pass@k and pass^k in every fixture case" do
    reference["pass_at_k"].each do |row|
      counts = { n: row["n"], c: row["c"], k: row["k"] }
      expect(described_class.pass_at(**counts)).to be_within(closed).of(row["pass_at_k"]), counts.inspect
      expect(described_class.pass_all(**counts)).to be_within(closed).of(row["pass_all_k"]), counts.inspect
    end
    expect { described_class.pass_at(n: 2, c: 1, k: 3) }.to raise_error(ArgumentError)
    expect { described_class.pass_all(n: 2, c: 3, k: 1) }.to raise_error(ArgumentError)
  end

  it "matches Newcombe's method 10 with the psi rule in every fixture case, at 95% and at other levels" do
    reference["newcombe_paired_95"].each do |row|
      difference, lower, upper = described_class.newcombe(**table(row), level: 0.95)
      expect([difference, lower, upper]).to match([be_within(closed).of(row["difference"]),
                                                   be_within(closed).of(row["lower"]),
                                                   be_within(closed).of(row["upper"])]), table(row).inspect
    end
    reference["newcombe_at_level"].each do |row|
      _, lower, upper = described_class.newcombe(**table(row), level: row["level"])
      expect([lower, upper]).to match([be_within(closed).of(row["lower"]), be_within(closed).of(row["upper"])])
    end
    expect { described_class.newcombe(a: 0, b: 0, c: 0, d: 0, level: 0.95) }.to raise_error(ArgumentError)
  end

  it "matches McNemar's exact test exactly, and its exact and incomplete-beta sums agree at 1,000" do
    reference["mcnemar_exact"].each do |b, c, binomtest, statsmodels|
      expect(described_class.mcnemar_exact(b:, c:)).to eq(binomtest).and eq(statsmodels)
    end
    # At b + c = 1,000 the exact Rational sum runs; the incomplete beta gives the same p.
    [0, 120, 470].each do |low|
      exact = described_class.mcnemar_exact(b: low, c: 1_000 - low)
      beta = 2 * Smith::Evals::Statistics::Distributions.incomplete_beta(0.5, 1_000 - low, low + 1)
      expect(beta).to be_within(1e-9 * exact).of(exact)
    end
    # Above 1,000, the incomplete beta; SciPy's binomtest(500, 1100) gives 0.0028195449914364293.
    expect(described_class.mcnemar_exact(b: 600, c: 500)).to be_within(1e-9 * 0.00282).of(0.0028195449914364293)
    expect { described_class.mcnemar_exact(b: -1, c: 2) }.to raise_error(ArgumentError)
  end

  it "gives McNemar's p at the largest counts: exactly 1 when the discordant pairs balance" do
    expect(described_class.mcnemar_exact(b: 200_000, c: 200_000)).to eq(1.0)
    expect(described_class.mcnemar_exact(b: 400_000, c: 400_050)).to be_within(1e-9).of(0.9563121823317147)
  end

  it "holds the beta posterior's point: one-sided when every trial passed or failed, moved at its level near them" do
    expect(described_class.beta_posterior(successes: 30, n: 30, level: 0.95))
      .to match([be_within(1e-12).of(0.05**(1.0 / 31)), eq(1.0)])
    expect(described_class.beta_posterior(successes: 0, n: 30, level: 0.95))
      .to match([eq(0.0), be_within(1e-12).of(1 - (0.05**(1.0 / 31)))])
    lower, upper = described_class.beta_posterior(successes: 0.99, n: 1.0, level: 0.95)
    expect(upper).to eq(0.99)
    expect(lower).to be_within(1e-9).of(0.17333381142036566)
    expect(described_class.beta_posterior(successes: 0.01, n: 1.0, level: 0.95))
      .to match([eq(0.01), be_within(1e-9).of(0.8266661885796337)])
    # With no size there is no point: the prior's interval stands.
    expect(described_class.beta_posterior(successes: 0, n: 0, level: 0.95))
      .to match([be_within(1e-12).of(0.025), be_within(1e-12).of(0.975)])
  end

  it "gives the beta posterior with no variation at a million samples" do
    expect(described_class.beta_posterior(successes: 500_000.0, n: 1_000_000.0, level: 0.95))
      .to match([be_within(1e-12).of(0.499020019683853), be_within(1e-12).of(0.500979980316147)])
  end

  it "matches SciPy's paired t interval and p-value; none for fewer than two pairs; no spread is zero wide" do
    row = reference["paired_t_95"]
    # SciPy's ttest_rel(x, y) reads x - y; Smith's t_paired(x, y) reads y - x.
    result = described_class.t_paired(row["y"], row["x"])
    expect(result).to match(point: be_within(closed).of(row["mean_difference"]),
                            lower: be_within(closed).of(row["lower"]), upper: be_within(closed).of(row["upper"]),
                            p_value: be_within(closed).of(row["p_value"]))
    expect { described_class.t_paired([0.5], [0.6]) }.to raise_error(ArgumentError)
    expect(described_class.t_paired([0.25, 0.5],
                                    [0.5, 0.75])).to eq(point: 0.25, lower: 0.25, upper: 0.25, p_value: 0.0)
    expect(described_class.t_paired([0.2, 0.4], [0.2, 0.4])).to include(point: 0.0, p_value: 1.0)
    # Equal differences whose float mean is not exact are still zero wide.
    expect(described_class.t_paired([0.0] * 100, [1.0 / 3] * 100))
      .to eq(point: 1.0 / 3, lower: 1.0 / 3, upper: 1.0 / 3, p_value: 0.0)
  end

  it "reads the p-value from the interval, in both fixture cases" do
    reference["interval_inversion_p"].each do |row|
      n = row.values_at("a", "b", "c", "d").sum
      point = (row["a"] + row["b"]).fdiv(n) - (row["a"] + row["c"]).fdiv(n)
      p_value = described_class.interval_p(point:, margin: row["margin"]) do |level|
        described_class.newcombe(**table(row), level:).drop(1)
      end
      expect(p_value).to be_within(closed).of(row["p"])
    end
    expect(described_class.interval_p(point: 0.01, margin: 0.02) { raise "not read" }).to eq(1.0)
  end

  it "matches statsmodels' Holm correction" do
    row = reference["holm"]
    adjusted, rejected = described_class.holm(row["p"], alpha: 0.05)

    expect(adjusted).to match(row["adjusted"].map { be_within(closed).of(_1) })
    expect(rejected).to eq(row["reject_at_0.05"])
    expect(described_class.holm([])).to eq([[], []])
  end

  it "reproduces the research table of sample sizes" do
    reference["sample_size"].each do |row|
      expect(described_class.unpaired_sample_size(p1: row["p1"], p2: row["p2"])).to eq(row["unpaired_per_arm"])
      [0.3, 0.5, 0.7].each do |rho|
        expect(described_class.paired_sample_size(p1: row["p1"], p2: row["p2"], correlation: rho))
          .to eq(row["paired_rho_#{rho}"])
      end
    end
  end

  it "finds the smallest detectable increase by bisection" do
    reference["detectable_increase_paired"].each do |row|
      delta = described_class.smallest_detectable(n: row["n"], baseline: row["baseline"], correlation: row["rho"],
                                                  direction: :increase)
      expect(delta).to be_within(closed).of(row["delta"])
    end
    expect { described_class.smallest_detectable(n: 9, baseline: 0.5, correlation: nil, direction: :up) }
      .to raise_error(ArgumentError)
  end

  it "says no change is detectable, rather than give the edge of its search" do
    %i[increase decrease].each do |direction|
      expect(described_class.smallest_detectable(n: 5, baseline: 0.5, correlation: nil, direction:)).to be_nil
    end
    # A 50-point change needs 10.5 samples per arm at 95% and 80% power: 9 detect none, 11 detect one.
    expect(described_class.smallest_detectable(n: 9, baseline: 0.5, correlation: nil, direction: :increase)).to be_nil
    expect(described_class.smallest_detectable(n: 11, baseline: 0.5, correlation: nil, direction: :increase))
      .to be < 0.5 - 1e-6
  end

  it "matches statsmodels' Cohen's kappa and Krippendorff's published alpha" do
    counts = reference["cohen_kappa"]["table"]
    pairs = ([[0,
               0]] * counts[0][0]) + ([[0, 1]] * counts[0][1]) + ([[1, 0]] * counts[1][0]) + ([[1, 1]] * counts[1][1])
    expect(described_class.cohen_kappa(pairs)).to be_within(closed).of(reference["cohen_kappa"]["kappa"])
    expect(described_class.cohen_kappa([%w[a a], %w[a a]])).to be_nil

    published = reference["krippendorff_alpha_nominal"]
    units = published["reliability_data"].transpose
    expect(described_class.krippendorff_alpha(units)).to be_within(closed).of(published["alpha"])
    expect(described_class.krippendorff_alpha([[1, 1], [1, nil]])).to be_nil
  end
end
