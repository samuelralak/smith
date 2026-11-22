# frozen_string_literal: true

require "smith/evals/statistics"

# Each function checks its inputs and raises ArgumentError outside its
# domain before any work; each bound is refused at its limit plus one.
RSpec.describe Smith::Evals::Statistics do
  def sample(id, trials, cluster = nil) = described_class::Sample.new(id:, trials:, cluster:)

  let(:two) { [sample("a", [true]), sample("b", [false])] }

  it "keeps a sample's id, trials and cluster, numbers as Floats, frozen" do
    built = sample(:s1, [true, 1, Rational(1, 2)], :c1)

    expect(built.to_h).to eq(id: "s1", trials: [true, 1.0, 0.5], cluster: "c1")
    expect([built, built.trials, built.id]).to all(be_frozen)
    [["", [true]], [nil, [true]], ["\xff", [true]], ["a", "true"], ["a", [2]], ["a", [nil]], ["a", [Float::NAN]]]
      .each { |id, trials| expect { sample(id, trials) }.to raise_error(ArgumentError) }
    expect { sample("a", [true], "") }.to raise_error(ArgumentError, /cluster/)
  end

  it "refuses more than 1,000 trials a sample" do
    expect(sample("a", [true] * 1_000).trials.size).to eq(1_000)
    expect { sample("a", [true] * 1_001) }.to raise_error(ArgumentError, /1000/)
  end

  it "refuses more than 1,000,000 samples before reading any" do
    one = sample("a", [true])

    expect { described_class.estimate(samples: Array.new(1_000_001, one), reducer: :any) }
      .to raise_error(ArgumentError, /1000000/)
    expect { described_class.compare(baseline: two, candidate: Array.new(1_000_001, one), reducer: :any) }
      .to raise_error(ArgumentError, /1000000/)
  end

  it "refuses more than 64 candidates" do
    candidates = Array.new(65) { |index| ["c#{index}", nil, nil] }

    expect do
      described_class.compare_many(baseline: two, candidates:, reducer: :any)
    end.to raise_error(ArgumentError, /64/)
    expect(described_class.compare_many(baseline: two, candidates: candidates.first(64), reducer: :any).candidates.size)
      .to eq(64)
  end

  it "refuses a bootstrap past 10**8 resamples times samples, rather than resampling less" do
    samples = Array.new(10) { |index| sample("s#{index}", [true, false]) }

    expect { described_class.estimate(samples:, reducer: "pass_at_1", resamples: 10_000_001) }
      .to raise_error(ArgumentError, /100000000/)
    many = Array.new(50_001) { |index| sample("s#{index}", [true, false]) }
    expect { described_class.compare(baseline: many, candidate: many, reducer: "pass_at_1") }
      .to raise_error(ArgumentError, /100000000/)
    expect { described_class.compare_many(baseline: many, candidates: [["c", nil, nil]], reducer: "pass_at_1") }
      .to raise_error(ArgumentError, /100000000/)
  end

  it "refuses fewer than 100 resamples, which would read a few draws as certainty" do
    samples = Array.new(10) { |index| sample("s#{index}", [true, index.even?], "k#{index % 5}") }

    expect { described_class.estimate(samples:, reducer: "pass_at_1", resamples: 99) }
      .to raise_error(ArgumentError, /resamples is an Integer of at least 100/)
    expect(described_class.estimate(samples:, reducer: "pass_at_1", resamples: 100).method_name).to eq("bootstrap")
  end

  it "states the reducer's limit of k from 1 to 99" do
    expect { described_class.estimate(samples: two, reducer: "pass_at_100") }
      .to raise_error(ArgumentError, /k from 1 to 99/)
  end

  it "refuses a bad reducer, scale, level, count, margin or seed" do
    [[{ reducer: :median }, /reducer/], [{ reducer: "pass_at_0" }, /reducer/], [{ reducer: "pass_at_100" }, /reducer/],
     [{ scale: :graded }, /scale/], [{ scale: :continuous, reducer: :majority }, /continuous/],
     [{ confidence: 1 }, /confidence/], [{ confidence: 0 }, /confidence/], [{ resamples: 0 }, /resamples/],
     [{ small_sample_threshold: 2.5 }, /small_sample_threshold/], [{ seed: -1 }, /seed/], [{ seed: "abc" }, /seed/]]
      .each do |change, message|
        expect { described_class.estimate(samples: two, reducer: :any, **change) }
          .to raise_error(ArgumentError, message), change.inspect
      end
    expect { described_class.compare(baseline: two, candidate: two, reducer: :any, margin: -0.1) }
      .to raise_error(ArgumentError, /margin/)
    expect { described_class.compare(baseline: two, candidate: two, reducer: :any, no_worse_margin: 0) }
      .to raise_error(ArgumentError, /no_worse_margin/)
  end

  it "refuses a confidence too near 1 for the levels read from it, plainly, at every entry point" do
    plain = /\Aconfidence is a number above 0 and at most 0\.999999999\z/
    many = Array.new(64) { |index| ["c#{index}", two, nil] }
    stats = described_class
    calls = {
      estimate: ->(level) { stats.estimate(samples: two, reducer: :any, confidence: level) },
      rate: ->(level) { stats.rate(successes: 1, total: 2, confidence: level) },
      compare: ->(level) { stats.compare(baseline: two, candidate: two, reducer: :any, confidence: level) },
      compare_many: ->(level) { stats.compare_many(baseline: two, candidates: many, reducer: :any, confidence: level) },
      detectable: ->(level) { stats.detectable(n: 50, baseline: 0.5, confidence: level) },
      required_samples: ->(level) { stats.required_samples(baseline: 0.5, difference: 0.1, confidence: level) },
      judge_check: ->(level) { stats.judge_check(caught: 1, failures: 2, passed: 1, good: 2, confidence: level) }
    }
    calls.each do |name, call|
      [1.0.prev_float, 0.9999999999999998, 0.999999999.next_float, 1, 0, -0.5].each do |confidence|
        expect { call.call(confidence) }.to raise_error(ArgumentError, plain), "#{name} at #{confidence}"
      end
      expect { call.call(0.999999999) }.not_to raise_error, name.to_s
    end
  end

  it "reads detectable at every baseline strictly between 0 and 1: a direction with no room reads null" do
    [1e-300, 1e-12, 1 - 1e-12, 1.0.prev_float].each do |baseline|
      result = described_class.detectable(n: 50, baseline:)
      expect(result.smallest_difference.values).to all(be_between(0, 1)), baseline.to_s
    end
    down = described_class::Formulas.smallest_detectable(n: 50, baseline: 1e-12, correlation: 0.5, direction: :decrease)
    expect(down).to be_nil
  end

  it "refuses samples that do not fit: duplicate ids, numbers on a binary scale, too few trials for pass@k" do
    expect { described_class.estimate(samples: [sample("a", [true]), sample("a", [false])], reducer: :any) }
      .to raise_error(ArgumentError, /"a" twice/)
    expect { described_class.estimate(samples: [sample("a", [0.5])], reducer: :mean) }
      .to raise_error(ArgumentError, /binary scale/)
    expect { described_class.estimate(samples: [sample("a", [true, true])], reducer: "pass_at_3") }
      .to raise_error(ArgumentError, /pass_at_3 needs at least 3/)
    expect { described_class.estimate(samples: [{ id: "a", trials: [true] }], reducer: :any) }
      .to raise_error(ArgumentError, /Sample/)
  end

  it "refuses a comparison with no pairs, or fewer than two for values" do
    other = [sample("z", [true])]

    expect { described_class.compare(baseline: two, candidate: other, reducer: :majority) }
      .to raise_error(ArgumentError, /at least one paired/)
    values = [sample("a", [0.5]), sample("z", [0.4])]
    expect { described_class.compare(baseline: values, candidate: values.last(1), reducer: :mean, scale: :continuous) }
      .to raise_error(ArgumentError, /at least two paired/)
  end

  it "refuses badly formed candidates" do
    [[["c", two]], [["c", two, :member_failed]], [["c", nil, "Bad Code"]], [["", two, nil]],
     [["c" * 129, two, nil]], [["c", two, nil], ["c", two, nil]], []].each do |candidates|
      expect { described_class.compare_many(baseline: two, candidates:, reducer: :any) }
        .to raise_error(ArgumentError), candidates.inspect
    end
    expect do
      described_class.compare_many(baseline: two, candidates: [["c", two, nil]], reducer: :any, baseline_label: "")
    end
      .to raise_error(ArgumentError, /baseline_label/)
  end

  it "refuses bad sizes and a bad judge check" do
    [{ n: 0, baseline: 0.8 }, { n: 10, baseline: 1.0 }, { n: 10, baseline: 0.8, paired: nil },
     { n: 10, baseline: 0.8, power: 1.2 }].each do |arguments|
      expect { described_class.detectable(**arguments) }.to raise_error(ArgumentError), arguments.inspect
    end
    [{ baseline: 0.8, difference: 0 }, { baseline: 0.8, difference: 0.2 }, { baseline: 0.8, difference: -0.8 }]
      .each do |arguments|
        expect { described_class.required_samples(**arguments) }.to raise_error(ArgumentError), arguments.inspect
      end
    counts = { caught: 1, failures: 2, passed: 1, good: 2 }
    [{ bar: { catches: 0.8 } }, { bar: { passes_good: 1.5 } }, { bar: 0.8 }, { gates_on: :sometimes }].each do |change|
      expect { described_class.judge_check(**counts, **change) }.to raise_error(ArgumentError), change.inspect
    end
    expect { described_class.rate(successes: 3, total: 2) }.to raise_error(ArgumentError, /at most the total/)
    expect { described_class.rate(successes: -1, total: 2) }.to raise_error(ArgumentError)
  end
end
