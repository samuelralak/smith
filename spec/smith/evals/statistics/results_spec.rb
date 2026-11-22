# frozen_string_literal: true

require "json"
require "smith/evals/statistics"

RSpec.describe Smith::Evals::Statistics do
  reference = JSON.parse(File.read(File.expand_path("../../../fixtures/evals/statistics_reference.json", __dir__)))
  closed = 1e-12

  def sample(id, trials, cluster = nil) = described_class::Sample.new(id:, trials:, cluster:)

  def votes(values)
    values.each_with_index.map { |value, index| sample(format("s-%03d", index), [value]) }
  end

  # Each value within 1e-12 (closed forms, design 7.0) of its expected one.
  def near(*expected, within: 1e-12) = match(expected.map { be_within(within).of(_1) })

  # A paired table as two runs: both pass, the candidate only, the baseline
  # only, neither (the reference generator's table_samples).
  def table_runs(both, candidate_only, baseline_only, neither)
    rows = ([[true, true]] * both) + ([[false, true]] * candidate_only) + ([[true, false]] * baseline_only) +
           ([[false, false]] * neither)
    [rows.each_with_index.map { |(was, _), index| sample(format("m-%02d", index), [was]) },
     rows.each_with_index.map { |(_, now), index| sample(format("m-%02d", index), [now]) }]
  end

  def valid!(result)
    hash = result.to_h
    expect(StatsSchema.errors(hash, strict: false)).to eq([]), "#{hash["type"]} as published"
    expect(StatsSchema.errors(hash, strict: true)).to eq([]), "#{hash["type"]} with unknown fields refused"
  end

  describe "estimate" do
    it "gives the passing example's design-effect case: 1.0334771746536450, Wilson 0.7841566056 to 0.9724934943" do
      row = reference["design_effect_wilson"].first
      samples = row["values"].each_with_index.map do |value, index|
        sample(format("d-%02d", index), [value == 1], row["clusters"][index])
      end
      estimate = described_class.estimate(samples:, reducer: :majority)

      expect(estimate.design_effect).to be_within(closed).of(1.0334771746536450)
      expect(estimate.n_effective).to be_within(1e-10).of(35.8014680028)
      expect([estimate.lower, estimate.upper]).to near(0.7841566056, 0.9724934943, within: 1e-10)
      expect([estimate.lower, estimate.upper]).to near(row["lower"], row["upper"])
      expect(estimate.to_h).to include("method" => "wilson", "n" => 37, "successes" => 34, "clusters" => 36,
                                       "warnings" => [])
      valid!(estimate)
    end

    it "gives the clamped case a design effect of 1" do
      # The fixture's case with no variation, and a cluster of a pass and a
      # fail, whose cluster-robust variance is below the independent one.
      row = reference["design_effect_wilson"].last
      steady = row["values"].each_with_index.map do |value, index|
        sample("e-#{index}", [value == 1], row["clusters"][index])
      end
      expect(described_class.estimate(samples: steady, reducer: :majority).design_effect).to eq(1.0)

      values = [true, false, true, true, true, true, false, false, false, false]
      mixed = values.each_with_index.map { |value, index| sample("m-#{index}", [value], index < 2 ? "a" : nil) }
      estimate = described_class.estimate(samples: mixed, reducer: :majority)
      expect([estimate.design_effect, estimate.n_effective, estimate.clusters]).to eq([1.0, 10.0, 9])
      expect([estimate.lower, estimate.upper]).to eq(described_class::Formulas.wilson(p: 0.5, n: 10.0, level: 0.95))
    end

    it "matches the seeded bootstrap fixture exactly, digest and seed included" do
      row = reference["bootstrap_splitmix_pass_at_2"]
      samples = row["samples"].map { |entry| sample(entry["id"], entry["trials"], entry["cluster"]) }
      estimate = described_class.estimate(samples: samples.reverse, reducer: "pass_at_2", resamples: row["resamples"])

      expect(estimate.to_h).to include("inputs_digest" => row["inputs_digest"], "seed" => row["seed"],
                                       "point" => row["point"], "lower" => row["lower"], "upper" => row["upper"],
                                       "method" => "bootstrap", "clusters" => 15, "approximate" => true)
      seeded = described_class.estimate(samples:, reducer: "pass_at_2", seed: 7)
      expect(seeded.seed).to eq("0000000000000007")
      expect(seeded.inputs_digest).not_to eq(row["inputs_digest"])
      valid!(estimate)
      valid!(seeded)
    end

    it "reads 21 of 23 as the additions design's example does" do
      estimate = described_class.estimate(samples: votes(([true] * 21) + ([false] * 2)), reducer: :majority)

      expect(estimate.to_h).to include("measure" => "pass_rate", "method" => "wilson", "n" => 23, "successes" => 21,
                                       "point" => 0.9130434782608695, "warnings" => ["small_sample"],
                                       "display" => { "unit" => "percent", "decimals" => 0, "point" => "91",
                                                      "lower" => "73", "upper" => "98" })
      expect([estimate.lower, estimate.upper]).to near(0.7320401892425634, 0.9758199955157796)
    end

    it "picks the beta posterior below 30 samples and t at 30 or more for a mean of pass/fail trials" do
      fractions = reference["beta_posterior_fractions"]
      small = fractions["fractions"].each_with_index.map do |value, index|
        sample("f-#{index}", Array.new(3) { |trial| trial < (value * 3).round })
      end
      beta = described_class.estimate(samples: small, reducer: :mean)
      expect(beta.method_name).to eq("beta_posterior")
      expect([beta.lower, beta.upper]).to near(fractions["lower"], fractions["upper"])

      large = Array.new(40) { |index| sample("g-#{index}", [index.even?, index % 3 != 0, true]) }
      t = described_class.estimate(samples: large, reducer: :mean)
      expect(t.to_h).to include("method" => "t", "approximate" => false)
      valid!(beta)
      valid!(t)
    end

    it "gives a continuous mean t, approximate below 30, and leaves samples with no trials out of n" do
      row = reference["t_interval_mean"]
      samples = row["values"].each_with_index.map { |value, index| sample("v-#{index}", [value]) }
      estimate = described_class.estimate(samples: samples + [sample("empty", [])], reducer: :mean, scale: :continuous)

      expect(estimate.to_h).to include("measure" => "mean", "method" => "t", "n" => 32, "approximate" => false)
      expect([estimate.lower, estimate.upper]).to near(row["lower"], row["upper"])
      expect(estimate.display["unit"]).to eq("score")
      few = described_class.estimate(samples: samples.first(5), reducer: :mean, scale: :continuous)
      expect(few.approximate).to be(true)
      valid!(estimate)
    end

    it "widens to the whole scale when the effective size leaves t no degrees of freedom" do
      # 30 samples in two clusters, each all passing or all failing: n / deff is 1.
      samples = Array.new(30) { |index| sample("h-#{index}", [index < 15, index < 15], index < 15 ? "a" : "b") }
      estimate = described_class.estimate(samples:, reducer: :mean)

      expect(estimate.n_effective).to be <= 1
      expect(estimate.to_h).to include("method" => "t", "lower" => 0.0, "upper" => 1.0)
      expect(estimate.warnings).to include("few_clusters", "interval_clipped")
      valid!(estimate)
    end

    it "decides exactly that every value is equal: 100 samples each passing 1 of 3 get the beta posterior" do
      samples = Array.new(100) { |index| sample(format("q-%03d", index), [true, false, false]) }
      estimate = described_class.estimate(samples:, reducer: :mean)

      expect(estimate.to_h).to include("method" => "beta_posterior", "point" => 1.0 / 3, "warnings" => ["no_variation"])
      expect([estimate.lower, estimate.upper]).to near(0.248606704300031224, 0.430665946270808378)
      valid!(estimate)
    end

    it "takes the beta posterior for every equal fraction of 3 to 10 trials, whatever the float mean" do
      (3..10).each do |trials|
        (1...trials).each do |passed|
          [30, 31, 47, 99, 100, 101, 300, 333, 997, 1000].each do |size|
            samples = Array.new(size) { |index| sample("e-#{index}", Array.new(trials) { |trial| trial < passed }) }
            estimate = described_class.estimate(samples:, reducer: :mean)
            expect([estimate.method_name, estimate.point, estimate.warnings])
              .to eq(["beta_posterior", passed.fdiv(trials), ["no_variation"]]), "#{passed}/#{trials}, n #{size}"
          end
        end
      end
    end

    it "gives equal values in clusters a design effect of 1: three samples of 0.1 in two clusters" do
      samples = [sample("a", [0.1], "x"), sample("b", [0.1], "x"), sample("c", [0.1], "y")]
      estimate = described_class.estimate(samples:, reducer: :mean, scale: :continuous)

      expect(estimate.to_h).to include("method" => "t", "clusters" => 2, "design_effect" => 1.0, "n_effective" => 3.0,
                                       "point" => 0.1, "lower" => 0.1, "upper" => 0.1, "approximate" => true)
      expect(estimate.warnings).to eq(%w[small_sample few_clusters no_variation])
      valid!(estimate)
    end

    it "reads samples that all share one cluster as one independent unit, with few_clusters" do
      samples = votes(([true] * 34) + ([false] * 3)).map { |entry| sample(entry.id, entry.trials, "one") }
      estimate = described_class.estimate(samples:, reducer: :majority)

      expect(estimate.to_h).to include("method" => "wilson", "n" => 37, "successes" => 34, "clusters" => 1,
                                       "design_effect" => 37.0, "n_effective" => 1.0, "warnings" => ["few_clusters"])
      expect([estimate.lower, estimate.upper]).to near(0.1747001535326037, 0.9983546774321088)
      means = Array.new(40) { |index| sample("o-#{index}", [(index % 7) / 10.0], "one") }
      mean = described_class.estimate(samples: means, reducer: :mean, scale: :continuous)
      expect(mean.to_h).to include("clusters" => 1, "n_effective" => 1.0, "lower" => 0.0, "upper" => 1.0)
      expect(mean.warnings).to eq(%w[few_clusters interval_clipped])
      valid!(estimate)
      valid!(mean)
    end

    it "widens to the whole scale at an effective size just above 1, as it does at 1, and never raises" do
      scores = Array.new(40) { |index| sample("k-#{index}", [index < 20 ? 0.9 : 0.1], index < 20 ? "a" : "b") }
      votes_of_ten = Array.new(40) do |index|
        sample("m-#{index}", Array.new(10) { |trial| trial < (index < 20 ? 9 : 1) }, index < 20 ? "a" : "b")
      end
      few = [0.91, 0.92, 0.93, 0.14, 0.15, 0.16].each_with_index.map do |value, index|
        sample("f-#{index}", [value], index < 3 ? "a" : "b")
      end
      [[scores, :continuous], [votes_of_ten, :binary], [few, :continuous]].each do |samples, scale|
        estimate = described_class.estimate(samples:, reducer: :mean, scale:)
        expect(estimate.n_effective).to be > 1
        expect(estimate.to_h).to include("method" => "t", "lower" => 0.0, "upper" => 1.0)
        expect(estimate.warnings).to include("few_clusters", "interval_clipped")
        valid!(estimate)
      end
      expect(described_class.estimate(samples: scores, reducer: :mean, scale: :continuous).n_effective)
        .to eq(1.0000000000000002)
    end

    it "gives the beta posterior with no variation at 500,000 samples" do
      samples = Array.new(500_000) { |index| sample("v#{index}", [true, false]) }
      estimate = described_class.estimate(samples:, reducer: :mean)

      expect(estimate.to_h).to include("method" => "beta_posterior", "point" => 0.5, "warnings" => ["no_variation"])
      expect([estimate.lower, estimate.upper]).to near(0.49861410091643216, 0.5013858990835678)
    end

    it "does not bootstrap fewer than two clusters: one cluster, or one sample, gets the whole scale" do
      row = reference["bootstrap_splitmix_pass_at_2"]
      one = row["samples"].map { |entry| sample(entry["id"], entry["trials"], "one") }
      estimate = described_class.estimate(samples: one, reducer: "pass_at_2")
      single = described_class.estimate(samples: [sample("a", [true, true, false])], reducer: "pass_at_2")

      expect(estimate.to_h).to include("method" => "bootstrap", "point" => row["point"], "lower" => 0.0, "upper" => 1.0,
                                       "clusters" => 1, "approximate" => true, "seed" => nil)
      expect(estimate.warnings).to eq(%w[few_clusters interval_clipped too_few_units])
      expect(single.to_h).to include("lower" => 0.0, "upper" => 1.0, "clusters" => nil, "seed" => nil)
      expect(single.warnings).to eq(%w[small_sample interval_clipped too_few_units])
      valid!(estimate)
      valid!(single)
    end

    it "holds its point when every trial passed or failed: the one-sided beta posterior at the same level" do
      passed = Array.new(30) { |index| sample(format("p-%02d", index), [true, true]) }
      all = described_class.estimate(samples: passed, reducer: :mean)
      none = described_class.estimate(samples: passed.map { |entry| sample(entry.id, [false, false]) }, reducer: :mean)

      # Round 2 read 88.8% to 99.9% around a point of 100%.
      expect(all.to_h).to include("method" => "beta_posterior", "point" => 1.0, "upper" => 1.0,
                                  "warnings" => ["no_variation"])
      expect(all.lower).to be_within(1e-12).of(0.9078859400526763)
      expect(all.display.values_at("point", "lower", "upper")).to eq(%w[100 91 100])
      expect(none.to_h).to include("point" => 0.0, "lower" => 0.0)
      expect(none.upper).to be_within(1e-12).of(0.0921140599473237)
      expect(none.display.values_at("point", "lower", "upper")).to eq(%w[0 0 9])
      { 2 => 0.3684031498640387, 3 => 0.4728708045015879, 7 => 0.6876560219336321 }.each do |size, lower|
        few = described_class.estimate(samples: passed.first(size), reducer: :mean)
        expect([few.point, few.lower, few.upper]).to near(1.0, lower, 1.0), "#{size} samples"
      end
      valid!(all)
      valid!(none)
    end

    it "holds its point near the ends and at low levels: the beta posterior moves, at its level, until it does" do
      # One cluster passing 100, 100 and 97 of 100: n_eff 1 and a point of 0.99, past the equal-tailed
      # interval's upper end, 0.98686.
      near_end = [100, 100, 97].each_with_index.map do |passed, index|
        sample("n-#{index}", Array.new(100) { |trial| trial < passed }, "one")
      end
      high = described_class.estimate(samples: near_end, reducer: :mean)
      # Three samples of 1 in 3 at 10%: Beta(2, 3), whose 45% quantile, 0.35732, is above 1/3.
      thirds = Array.new(3) { |index| sample("t-#{index}", [true, false, false]) }
      low = described_class.estimate(samples: thirds, reducer: :mean, confidence: 0.1)

      expect(high.point).to be_within(1e-15).of(0.99)
      expect(high.upper).to eq(high.point)
      expect(high.lower).to be_within(1e-9).of(0.17333381142036533)
      expect([low.point, low.lower]).to eq([1.0 / 3, 1.0 / 3])
      expect(low.upper).to be_within(1e-9).of(0.38997483548063117)
      valid!(high)
      valid!(low)
    end

    it "holds a bootstrap's point in its interval to the last digit, and at low levels" do
      # One sample passing 1 of 3 in cluster a, seven passing 2 of 3 in b: pass@1 is 0.625, and at 50%
      # the upper percentile falls on resamples of the data itself, whose sum rounds to 0.6249999999999999.
      rounded = Array.new(8) do |index|
        index.zero? ? sample("r-0", [true, false, false], "a") : sample("r-#{index}", [true, true, false], "b")
      end
      half = described_class.estimate(samples: rounded, reducer: "pass_at_1", confidence: 0.5)
      expect(half.point).to eq(0.625)
      expect(half.upper).to eq(0.625)
      expect(half.lower).to be_within(1e-15).of(1.0 / 3)

      # 40 samples of 10 trials in six clusters: at 1% the resamples' middle, 0.3204 to 0.3214, sits above
      # pass^2's mean, 0.32.
      skewed = Array.new(40) do |index|
        sample("k-#{index}", Array.new(10) { |trial| trial < (index * 3) % 11 }, "c#{index % 6}")
      end
      low = described_class.estimate(samples: skewed, reducer: "pass_all_2", confidence: 0.01)
      expect(low.lower).to eq(low.point)
      expect(low.upper).to be > low.point
      valid!(half)
      valid!(low)
    end

    it "leaves a seed out of the digest of a result it cannot change" do
      plain = described_class.estimate(samples: votes([true, false, true]), reducer: :majority)
      seeded = described_class.estimate(samples: votes([true, false, true]), reducer: :majority, seed: 5)

      expect([seeded.inputs_digest, seeded.seed]).to eq([plain.inputs_digest, nil])
    end

    it "matches the reference generator on every review ruling case in the fixture" do
      reference["review_rulings"].except("note", "not_detectable").each do |name, row|
        samples = row["samples"].map { |entry| sample(entry["id"], entry["trials"], entry["cluster"]) }
        options = { reducer: row["reducer"], scale: row["scale"], confidence: row.fetch("confidence", 0.95) }
        estimate = described_class.estimate(samples:, **options).to_h

        expect(estimate.slice("method", "clusters", "warnings", "seed"))
          .to eq(row.slice("method", "clusters", "warnings", "seed")), name
        %w[point lower upper design_effect n_effective].each do |field|
          expected = row[field]
          matcher = expected.nil? ? be_nil : be_within(closed).of(expected)
          expect(estimate[field]).to matcher, "#{name} #{field}"
        end
      end
      reference["review_rulings"]["not_detectable"].each do |row|
        result = described_class.detectable(n: row["n"], baseline: row["baseline"], paired: row["paired"])
        expect(result.display).to eq(row["display"])
        row["smallest_difference"].each do |name, expected|
          actual = result.smallest_difference[name]
          expected.nil? ? expect(actual).to(be_nil) : expect(actual).to(be_within(closed).of(expected))
        end
      end
    end

    it "says so when there are no samples, and warns of uneven trials" do
      empty = described_class.estimate(samples: [sample("a", [])], reducer: :majority)
      expect(empty.to_h).to include("n" => 0, "point" => nil, "successes" => nil, "warnings" => ["no_samples"])
      uneven = described_class.estimate(samples: [sample("a", [true]), sample("b", [true, false])], reducer: :any)
      expect(uneven.warnings).to eq(%w[uneven_trials small_sample])
      valid!(empty)
      valid!(uneven)
    end
  end

  describe "rate" do
    it "is Wilson on counts, and says so when there are none" do
      expect(described_class.rate(successes: 27, total: 30).to_h)
        .to include("measure" => "rate", "basis" => "counts", "reducer" => nil, "n" => 30, "successes" => 27)
      expect(described_class.rate(successes: 0, total: 0).to_h).to include("point" => nil, "warnings" => ["no_samples"])
      valid!(described_class.rate(successes: 27, total: 30))
      valid!(described_class.rate(successes: 0, total: 0))
    end
  end

  describe "compare" do
    it "reads its p-value from its interval: 0.0318959603 and 0.0158673688" do
      { [23, 11, 3, 0] => 0.0318959603, [94, 11, 2, 13] => 0.0158673688 }.each do |counts, expected|
        baseline, candidate = table_runs(*counts)
        comparison = described_class.compare(baseline:, candidate:, reducer: :majority)
        expect(comparison.p_value).to be_within(1e-10).of(expected)
        valid!(comparison)
      end
    end

    it "reads the additions design's 120-pair comparison" do
      baseline, candidate = table_runs(94, 11, 2, 13)
      comparison = described_class.compare(baseline:, candidate:, reducer: :majority).to_h

      expect(comparison).to include("method" => "newcombe_paired", "pairs" => 120, "verdict" => "better",
                                    "changed" => { "better" => 11, "worse" => 2, "same" => 107 },
                                    "test" => { "method" => "mcnemar_exact", "p_value" => 0.0224609375 },
                                    "verdict_rule" => "interval_vs_margin/1", "no_worse" => nil)
      expect(comparison["difference"].values).to near(0.075, 0.014926603950636157, 0.13938784672990062)
      expect(comparison["display"]).to eq("unit" => "points", "decimals" => 1, "point" => "+7.5", "lower" => "+1.5",
                                          "upper" => "+13.9")
    end

    it "counts unpaired samples, notes shared clusters and fills the no-worse reading at its own level" do
      baseline = votes([true, false, true, true]) + [sample("only-b", [true])]
      candidate = votes([true, true, true, false]) + [sample("only-c", [false])]
      shared = baseline.map { |entry| sample(entry.id, entry.trials, "one") }
      comparison = described_class.compare(baseline: shared, candidate:, reducer: :majority, no_worse_margin: 0.5)
      lower = comparison.difference["lower"]

      expect(comparison.to_h).to include("pairs" => 4, "only_in_baseline" => 1, "only_in_candidate" => 1)
      expect(comparison.warnings).to eq(%w[unpaired_samples small_sample clusters_ignored])
      expect(comparison.no_worse).to eq("margin" => 0.5, "level" => 0.95, "lower" => lower, "holds" => lower > -0.5)
      valid!(comparison)
    end

    it "reads equal paired differences as no variation, decided exactly" do
      baseline = Array.new(100) { |index| sample(format("d-%03d", index), [false, false, false]) }
      candidate = baseline.map { |entry| sample(entry.id, [true, false, false]) }
      comparison = described_class.compare(baseline:, candidate:, reducer: :mean)

      expect(comparison.difference).to eq("point" => 1.0 / 3, "lower" => 1.0 / 3, "upper" => 1.0 / 3)
      expect(comparison.warnings).to eq(["no_variation"])
      expect(comparison.test).to eq("method" => "t_paired", "p_value" => 0.0)
      valid!(comparison)
    end

    it "compares values by paired t, with the classic p beside it" do
      row = reference["paired_t_95"]
      baseline = row["y"].each_with_index.map { |value, index| sample("p-#{index}", [value]) }
      candidate = row["x"].each_with_index.map { |value, index| sample("p-#{index}", [value]) }
      comparison = described_class.compare(baseline:, candidate:, reducer: :mean, scale: :continuous)

      expect(comparison.to_h).to include("method" => "t_paired", "approximate" => true)
      expect([comparison.difference["lower"], comparison.test["p_value"]]).to near(row["lower"], row["p_value"])
      expect(comparison.display["unit"]).to eq("score")
      valid!(comparison)
    end
  end

  describe "compare_many" do
    let(:runs) do
      baseline, first = table_runs(23, 11, 3, 0)
      _, second = table_runs(26, 6, 5, 0)
      _, third = table_runs(20, 4, 9, 4)
      relabel = ->(run) { baseline.zip(run).map { |was, now| sample(was.id, now.trials) } }
      [baseline, first, relabel.call(second), relabel.call(third)]
    end

    it "gives the fixture's p-values, adjusted values, levels, intervals and verdicts" do
      baseline, *named = runs
      candidates = %w[cand_a cand_b cand_c].zip(named).map { |label, run| [label, run, nil] }
      set = described_class.compare_many(baseline:, candidates:, reducer: :majority)

      set.candidates.zip(reference["compare_many_holm"]["candidates"]).each do |row, expected|
        expect(row.label).to eq(expected["label"])
        expect([row.p_value, row.adjusted_p, row.level]).to near(*expected.values_at("p_value", "adjusted_p", "level"))
        expect(row.comparison.difference.values_at("lower", "upper")).to near(*expected.values_at("lower", "upper"))
        expect([row.verdict, row.comparison.verdict]).to eq([expected["verdict"]] * 2)
        expect(row.comparison.confidence).to eq(row.level)
      end
      expect(set.candidates.first.comparison.display.values_at("lower", "upper")).to eq(%w[-2.6 +43.2])
      expect(set.adjustment).to eq("method" => "holm", "method_revision" => 1, "comparisons" => 3,
                                   "family_confidence" => 0.95)
      valid!(set)
    end

    it "reads each candidate's no-worse lower bound at 1 - alpha/m over every candidate named, and records it" do
      baseline, first, second = runs
      candidates = [["cand_a", first, nil], ["cand_b", second, nil], ["cand_x", nil, :member_failed]]
      set = described_class.compare_many(baseline:, candidates:, reducer: :majority, no_worse_margin: 0.05)
      level = 1 - (0.05 / 3)

      expect(set.no_worse_margin).to eq(0.05)
      expect(set.no_worse_adjustment).to eq("method" => "bonferroni", "comparisons" => 3, "level" => level)
      set.candidates.first(2).zip([first, second]).each do |row, run|
        lower = described_class.compare(baseline:, candidate: run, reducer: :majority, confidence: level)
                               .difference["lower"]
        expect(row.no_worse).to eq("margin" => 0.05, "level" => level, "lower" => lower, "holds" => lower > -0.05)
        expect(row.comparison.no_worse).to be_nil
      end
      expect(set.candidates.last.to_h).to include("status" => "not_compared", "reason_code" => "member_failed",
                                                  "p_value" => nil, "no_worse" => nil)
      valid!(set)
    end

    it "keeps the no-worse family off Holm's step levels when Holm rejects a candidate" do
      baseline, = runs
      strong = baseline.map { |was| sample(was.id, [true]) }
      second = runs[2]
      candidates = [["strong", strong, nil], ["second", second, nil], ["gone", nil, :member_incomplete]]
      set = described_class.compare_many(baseline:, candidates:, reducer: :majority, no_worse_margin: 0.05)
      bonferroni = 1 - (0.05 / 3)

      expect(set.candidates.map(&:level)).to eq([bonferroni, 0.975, nil])
      lower = described_class.compare(baseline:, candidate: second, reducer: :majority, confidence: bonferroni)
                             .difference["lower"]
      expect(set.candidates[1].no_worse).to include("level" => bonferroni, "lower" => lower)
      expect(set.candidates[1].comparison.difference["lower"]).not_to eq(lower)
    end

    it "is compare itself for one candidate" do
      baseline, first = runs
      set = described_class.compare_many(baseline:, reducer: :majority, no_worse_margin: 0.05,
                                         candidates: [["only", first, nil]])
      single = described_class.compare(baseline:, candidate: first, reducer: :majority)
      reading = described_class.compare(baseline:, candidate: first, reducer: :majority, no_worse_margin: 0.05)

      expect(set.candidates.first.comparison.to_h).to eq(single.to_h)
      expect(set.candidates.first.no_worse).to eq(reading.no_worse)
      expect(set.no_worse_adjustment["level"]).to eq(0.95)
    end
  end

  describe "sizes" do
    it "gives detectable(n: 120, baseline: 0.8) as 0.0852, 0.1112 and 0.1326" do
      result = described_class.detectable(n: 120, baseline: 0.8)
      expected = reference["detectable_paired_range"]["smallest_difference"]

      expect(result.smallest_difference.values).to near(0.0852, 0.1112, 0.1326, within: 5e-5)
      expect(result.smallest_difference.values).to near(*expected.values_at("low", "typical", "high"))
      expect(result.display).to eq("unit" => "points", "decimals" => 0, "low" => "9", "typical" => "11", "high" => "13")
      expect(result.assumptions).to eq("correlation" => { "low" => 0.7, "typical" => 0.5, "high" => 0.3 })
      valid!(result)
    end

    it "gives required_samples(0.8, 0.05) as 275, 455 and 634" do
      result = described_class.required_samples(baseline: 0.8, difference: 0.05)

      expect(result.samples).to eq("low" => 275, "typical" => 455, "high" => 634)
      expect(result.display.values_at("low", "typical", "high")).to eq(%w[275 455 634])
      valid!(result)
    end

    it "says when no change is detectable at the size, never the edge of its search" do
      [[5, 0.5, false], [8, 0.5, false], [1, 0.8, true]].each do |n, baseline, paired|
        result = described_class.detectable(n:, baseline:, paired:)

        expect(result.smallest_difference).to eq("low" => nil, "typical" => nil, "high" => nil), [n, baseline].inspect
        expect(result.display).to eq("unit" => "points", "decimals" => 0, "low" => nil, "typical" => nil, "high" => nil)
        valid!(result)
      end
      mixed = described_class.detectable(n: 7, baseline: 0.5)
      expect(mixed.smallest_difference["high"]).to be_nil
      expect(mixed.smallest_difference.values_at("low", "typical")).to all(be_between(0.3, 0.5))
      valid!(mixed)
    end

    it "refuses a difference so small that its sizes pass 2**53 - 1" do
      expect { described_class.required_samples(baseline: 0.5, difference: 1e-9) }
        .to raise_error(ArgumentError, /2\*\*53 - 1/)
    end

    it "gives one size for unpaired runs, the correlation null" do
      result = described_class.required_samples(baseline: 0.8, difference: 0.05, paired: false)

      expect(result.samples).to eq("low" => 906, "typical" => 906, "high" => 906)
      expect(result.assumptions).to eq("correlation" => nil)
      valid!(result)
      valid!(described_class.detectable(n: 120, baseline: 0.8, paired: false))
    end
  end

  describe "judge_check" do
    it "reads both rates against the bar, on the point and with confidence, gating on the lower bound by default" do
      check = described_class.judge_check(caught: 27, failures: 30, passed: 55, good: 58,
                                          bar: { catches_failures: 0.8, passes_good: 0.85 })

      expect(check.to_h).to include("gates_on" => "with_confidence",
                                    "bar" => { "catches_failures" => 0.8, "passes_good" => 0.85 })
      expect(check.meets_bar).to eq("catches_failures" => { "on_point" => true, "with_confidence" => false },
                                    "passes_good" => { "on_point" => true, "with_confidence" => true })
      expect(check.catches_failures.display.values_at("point", "lower", "upper")).to eq(%w[90 74 97])
      valid!(check)
      valid!(described_class.judge_check(caught: 1, failures: 2, passed: 0, good: 0, gates_on: :on_point))
    end
  end

  it "gives frozen results whose to_h is the smith.evals.stats/1 form, keys in the schema's order" do
    estimate = described_class.rate(successes: 3, total: 4)

    expect(estimate).to be_frozen
    expect([estimate.warnings, estimate.display, estimate.display["point"]]).to all(be_frozen)
    expect(estimate.to_h.keys).to eq(StatsSchema.documents["stats"]["$defs"]["estimate"]["required"])
    expect(estimate.to_h).to include("schema" => "smith.evals.stats/1", "type" => "estimate", "method" => "wilson")
    expect(estimate.method_name).to eq("wilson")
  end

  it "publishes schemas that are valid JSON Schema 2020-12, and the strict copy refuses an unknown field" do
    require "json_schemer"
    StatsSchema.documents.each_value { |schema| expect(JSONSchemer.valid_schema?(schema)).to be(true) }

    hash = described_class.rate(successes: 3, total: 4).to_h.merge("extra" => 1)
    expect(StatsSchema.errors(hash, strict: false)).to eq([])
    expect(StatsSchema.errors(hash, strict: true)).not_to be_empty
  end
end
