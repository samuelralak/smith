# frozen_string_literal: true

require "json"
require "open3"
require "smith/canonical_json"
require "smith/evals/statistics"

# The property tests of slice-1a design 12.1 (done-when 2), with a few of the
# additions design's (4.8). Inputs come from a seeded SplitMix64, so every
# run checks the same cases.
RSpec.describe "Smith::Evals::Statistics properties" do
  statistics = Smith::Evals::Statistics
  formulas = statistics::Formulas
  distributions = statistics::Distributions

  let(:draws) { statistics::SplitMix64.new(20_261_122) }

  def sample(id, trials, cluster = nil) = Smith::Evals::Statistics::Sample.new(id:, trials:, cluster:)
  def heads?(draws, share) = draws.below(1_000_000) < share * 1_000_000

  # A run of samples of some trials, each sample passing at its own rate,
  # some in shared clusters.
  def run(draws, size, trials: 1, clusters: 0)
    Array.new(size) do |index|
      rate = draws.below(101) / 100.0
      cluster = "k#{draws.below(clusters)}" if clusters.positive? && heads?(draws, 0.5)
      sample(format("s-%03d", index), Array.new(trials) { heads?(draws, rate) }, cluster)
    end
  end

  # The same samples with some outcomes flipped.
  def flipped(draws, baseline)
    share = draws.below(60) / 100.0
    baseline.map do |entry|
      sample(entry.id, entry.trials.map { |trial| heads?(draws, share) ? !trial : trial }, entry.cluster)
    end
  end

  def strict_errors(result) = StatsSchema.errors(result.to_h, strict: true)

  it "keeps Wilson's bounds within 0..1 and around the point for every k of n up to 200" do
    (1..200).each do |n|
      (0..n).each do |k|
        lower, upper = formulas.wilson(p: k.fdiv(n), n:, level: 0.95)
        expect(k.fdiv(n).between?(lower, upper) && lower >= 0 && upper <= 1).to be(true), "#{k} of #{n}"
      end
    end
  end

  it "gives a design effect of 1 when every cluster is a singleton, and never below 1" do
    200.times do
      size = 2 + draws.below(80)
      values = Array.new(size) { draws.below(3).zero? ? 0 : 1 }
      expect(formulas.design_effect(values, Array.new(size) { |index| "s:#{index}" }).first).to eq(1.0)
      keys = Array.new(size) { "c:#{draws.below(1 + draws.below(size))}" }
      expect(formulas.design_effect(values, keys).first).to be >= 1.0
    end
  end

  # Within 1e-9 of q, or, where the root sits a few floats from 1, as close as
  # a float can be: q lies between I at the floats either side of x.
  it "inverts the incomplete beta with the beta quantile on a grid" do
    [0.3, 0.5, 1, 2.5, 10, 27.5, 400].product([0.5, 1, 4.5, 30, 1_000]).each do |a, b|
      [1e-6, 0.025, 0.2, 0.5, 0.8, 0.975, 0.999999].each do |q|
        x = distributions.beta_quantile(q, a, b)
        close = (distributions.incomplete_beta(x, a, b) - q).abs <= 1e-12 + (1e-9 * q)
        neighbours = [x.prev_float, x.next_float].map { |float| distributions.incomplete_beta(float, a, b) }
        expect(close || q.between?(*neighbours)).to be(true), [q, a, b].inspect
      end
    end
  end

  it "brings the t quantile to the normal quantile as degrees of freedom grow" do
    [0.6, 0.9, 0.975, 0.999].each do |p|
      gaps = [1, 2, 5, 10, 30, 100, 1_000, 100_000].map do |df|
        distributions.t_quantile(p, df) - distributions.normal_quantile(p)
      end
      expect(gaps).to all(be_positive)
      expect(gaps.each_cons(2).all? { |wider, narrower| narrower < wider }).to be(true), p.to_s
      expect(gaps.last).to be < 1e-3
    end
  end

  it "keeps Newcombe's interval around its point" do
    (0..12).to_a.repeated_permutation(4).each_slice(97).map(&:first).each do |a, b, c, d|
      next if a + b + c + d < 1

      difference, lower, upper = formulas.newcombe(a:, b:, c:, d:, level: 0.95)
      expect(difference.between?(lower, upper)).to be(true), [a, b, c, d].inspect
    end
  end

  it "keeps Holm's adjusted values monotone in p, at least p and at most 1" do
    100.times do
      p_values = Array.new(1 + draws.below(12)) { draws.below(1_000).zero? ? 1.0 : draws.below(10_000) / 10_000.0 }
      adjusted, rejected = formulas.holm(p_values)
      in_order = p_values.each_index.sort_by { |index| [p_values[index], index] }.map { |index| adjusted[index] }
      expect(in_order.each_cons(2).all? { |low, high| low <= high }).to be(true)
      expect(adjusted.zip(p_values).all? { |value, p| value.between?(p, 1) }).to be(true)
      expect(rejected).to eq(adjusted.map { |value| value <= 0.05 })
    end
  end

  it "never lets a compare_many verdict contradict its own interval, raw or shown" do
    40.times do
      baseline = run(draws, 10 + draws.below(50))
      candidates = Array.new(1 + draws.below(4)) do |index|
        draws.below(6).zero? ? ["c#{index}", nil, :member_incomplete] : ["c#{index}", flipped(draws, baseline), nil]
      end
      margin = [0.0, 0.0, 0.05][draws.below(3)]
      set = statistics.compare_many(baseline:, candidates:, reducer: :majority, margin:)
      set.candidates.select { |row| row.status == "compared" }.each do |row|
        lower, upper = row.comparison.difference.values_at("lower", "upper")
        expected = if lower > margin then "better"
                   elsif upper.negative? then "worse"
                   else "inconclusive"
                   end
        expect(row.verdict).to eq(expected)
        shown = row.comparison.display
        next if shown["decimals"] == 3

        expect(shown["lower"].to_f > margin * 100).to be(true) if row.verdict == "better"
        expect(shown["upper"].to_f.negative?).to be(true) if row.verdict == "worse"
      end
      expect(strict_errors(set)).to eq([])
    end
  end

  it "keeps lower <= point <= upper, widens with confidence, mirrors comparisons and ignores order" do
    30.times do
      baseline = run(draws, 8 + draws.below(60), trials: 3, clusters: 6)
      candidate = flipped(draws, baseline)
      reducer = [:majority, :any, :all, :mean, "pass_at_2"][draws.below(5)]
      narrow, wide = [0.8, 0.99].map { |confidence| statistics.estimate(samples: baseline, reducer:, confidence:) }
      expect(narrow.point.between?(narrow.lower, narrow.upper)).to be(true)
      expect(wide.lower <= narrow.lower && narrow.upper <= wide.upper).to be(true) unless reducer == "pass_at_2"

      forward = statistics.compare(baseline:, candidate:, reducer: :majority)
      backward = statistics.compare(baseline: candidate, candidate: baseline, reducer: :majority)
      expect(backward.difference.values_at("point", "lower", "upper"))
        .to match(forward.difference.values_at("point", "upper", "lower").map { be_within(1e-12).of(-_1) })
      shuffled = statistics.compare(baseline: baseline.reverse, candidate: candidate.rotate(3), reducer: :majority)
      expect(shuffled.to_h).to eq(forward.to_h)
      [narrow, wide, forward, backward].each { |result| expect(strict_errors(result)).to eq([]) }
    end
  end

  # A run that mostly or wholly passes, or fails: where the equal-tailed
  # forms leave their point out.
  def lopsided(draws, size, trials)
    share = [0.0, 0.02, 0.98, 1.0][draws.below(4)]
    Array.new(size) do |index|
      sample(format("l-%03d", index), Array.new(trials) { heads?(draws, share) }, ("k#{index % 3}" if index.odd?))
    end
  end

  # Lower <= point <= upper, in the numbers and in the text shown.
  def holds?(point, lower, upper, display)
    shown = display&.values_at("point", "lower", "upper")&.map { |text| Rational(text) }
    point.between?(lower, upper) && (shown.nil? || shown[0].between?(shown[1], shown[2]))
  end

  it "shows every point inside its interval at any level: estimates, rates, comparisons and sets" do
    levels = [0.01, 0.1, 0.3, 0.5, 0.8, 0.95, 0.999999999]
    60.times do |round|
      level = levels[round % levels.size]
      size = 2 + draws.below(40)
      trials = 1 + draws.below(4)
      baseline = round.even? ? lopsided(draws, size, trials) : run(draws, size, trials:, clusters: 4)
      candidate = flipped(draws, baseline)
      [:majority, :mean, "pass_at_1", "pass_all_#{[2, trials].min}"].each do |reducer|
        next if reducer.to_s.start_with?("pass_all") && trials < 2

        estimate = statistics.estimate(samples: baseline, reducer:, confidence: level, resamples: 200)
        expect(holds?(estimate.point, estimate.lower, estimate.upper, estimate.display))
          .to be(true), "#{reducer} at #{level}: #{estimate.to_h.slice("point", "lower", "upper")}"
      end
      rate = statistics.rate(successes: draws.below(size + 1), total: size, confidence: level)
      expect(holds?(rate.point, rate.lower, rate.upper, rate.display)).to be(true)
      comparison = statistics.compare(baseline:, candidate:, reducer: :mean, confidence: level)
      set = statistics.compare_many(baseline:, candidates: [["a", candidate, nil], ["b", baseline, nil]],
                                    reducer: :majority, confidence: level)
      [comparison, *set.candidates.map(&:comparison)].each do |result|
        difference = result.difference
        expect(holds?(*difference.values_at("point", "lower", "upper"), nil)).to be(true)
        [result.baseline, result.candidate].each do |side|
          expect(holds?(side.point, side.lower, side.upper, side.display))
            .to be(true), "#{side.method_name} at #{level}"
        end
      end
    end
  end

  it "gives byte-identical JSON for the same inputs in two subprocesses" do
    script = <<~RUBY
      require "json"
      require "smith/canonical_json"
      require "smith/evals/statistics"
      S = Smith::Evals::Statistics
      run = Array.new(40) do |i|
        S::Sample.new(id: "s-\#{i}", trials: [i % 3 != 0, i % 5 != 0, i.even?], cluster: "k\#{i / 3}")
      end
      other = run.map { |s| S::Sample.new(id: s.id, trials: s.trials.map(&:!).rotate, cluster: s.cluster) }
      results = [
        S.estimate(samples: run, reducer: :majority), S.estimate(samples: run, reducer: "pass_at_2"),
        S.estimate(samples: run, reducer: :mean), S.rate(successes: 21, total: 23),
        S.compare(baseline: run, candidate: other, reducer: :majority, no_worse_margin: 0.05),
        S.compare_many(baseline: run, candidates: [["a", other, nil], ["b", run, nil], ["c", nil, :member_failed]],
                       reducer: :majority, no_worse_margin: 0.05),
        S.detectable(n: 120, baseline: 0.8), S.required_samples(baseline: 0.8, difference: 0.05),
        S.judge_check(caught: 27, failures: 30, passed: 55, good: 58, bar: { catches_failures: 0.8 })
      ]
      print results.map { |result| [Smith::CanonicalJSON.generate(result.to_h), JSON.generate(result.to_h)] }
                   .flatten.join("\\n")
    RUBY
    outputs = Array.new(2) do
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../../../lib", __dir__),
                                              "-e", script)
      raise stderr unless status.success?

      stdout
    end

    expect(outputs.first.lines.size).to eq(18)
    expect(outputs.first).to eq(outputs.last)
    outputs.first.lines.each_slice(2) do |canonical, _|
      expect(StatsSchema.errors(JSON.parse(canonical), strict: true)).to eq([])
    end
  end
end
