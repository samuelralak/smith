# frozen_string_literal: true

require "json"
require "smith/evals/statistics"

RSpec.describe Smith::Evals::Statistics::Distributions do
  reference = JSON.parse(File.read(File.expand_path("../../../fixtures/evals/statistics_reference.json", __dir__)))
  t_reference = JSON.parse(File.read(File.expand_path("../../../fixtures/evals/t_quantile_reference.json", __dir__)))

  # Quantiles and the incomplete beta: 1e-9 relative (design 7.0).
  def relative(actual, expected) = expected.zero? ? actual.abs : ((actual - expected) / expected).abs

  it "matches SciPy's normal quantile at every fixture point; 0.5 is exactly 0" do
    reference["normal_quantile"].each do |p, expected|
      expect(relative(described_class.normal_quantile(p), expected)).to be < 1e-9, p.to_s
    end
    expect(described_class.normal_quantile(0.5)).to eq(0.0)
    expect(described_class.normal_quantile(0.975)).to be_within(1e-15).of(1.959963984540054)
  end

  it "matches SciPy's t quantile at every fixture point" do
    reference["t_quantile_0975"].each do |df, expected|
      expect(relative(described_class.t_quantile(0.975, df), expected)).to be < 1e-9, "df #{df}"
    end
    reference["t_quantile_other"].each do |p, df, expected|
      expect(relative(described_class.t_quantile(p, df), expected)).to be < 1e-9, "p #{p} df #{df}"
    end
  end

  it "gives t's closed forms for 1 and 2 degrees of freedom, odd in p, 0 at 0.5" do
    [0.001, 0.025, 0.3, 0.6, 0.9, 0.975, 0.999].each do |p|
      expect(relative(described_class.t_quantile(p, 1), Math.tan(Math::PI * (p - 0.5)))).to be < 1e-9
      expect(relative(described_class.t_quantile(p, 2), ((2 * p) - 1) / Math.sqrt(2 * p * (1 - p)))).to be < 1e-9
    end
    # Odd wherever 1 - p is exact (above 0.5 it always is).
    [0.6, 0.9, 0.975, 0.999, 1 - 1e-12].each do |p|
      expect(described_class.t_quantile(1 - p, 7.5)).to eq(-described_class.t_quantile(p, 7.5))
    end
    expect(described_class.t_quantile(0.5, 3)).to eq(0.0)
  end

  it "gives t's quantile within 1e-10 relative at every level and degree of freedom of the high-precision grid" do
    t_reference["cases"].each do |p, df, expected|
      expect(relative(described_class.t_quantile(p, df), expected)).to be < 1e-10, "p #{p} df #{df}"
    end
  end

  it "keeps t's quantile near p = 0.5 and in a far lower tail, and above the normal's past 1e7 degrees of freedom" do
    # 1 - x is solved for directly, so it is not quantized near 1 (2.50662890e-6, not 2.98e-5).
    expect(relative(described_class.t_quantile(0.500001, 1e6), 2.5066289013628524e-6)).to be < 1e-10
    expect(relative(described_class.t_quantile(1e-20, 5), -15_683.925454365775)).to be < 1e-10
    expect(described_class.t_quantile(0.975, 2e7)).to be > described_class.normal_quantile(0.975)
    expect(described_class.t_quantile(0.975, 0.5)).to be > described_class.t_quantile(0.975, 1)
  end

  it "gives t's quantile at any degrees of freedom above 0, infinity where it passes the largest Float" do
    expect(relative(described_class.t_quantile(0.999, 0.1), 1.6044257056665492e26)).to be < 1e-10
    expect(described_class.t_quantile(0.975, 2.220446049250313e-16)).to eq(Float::INFINITY)
    expect(described_class.t_quantile(0.025, 2.220446049250313e-16)).to eq(-Float::INFINITY)
    expect(described_class.t_quantile(0.975, 0.00045)).to eq(Float::INFINITY)
    # Near p = 0.5 at tiny df the middle comes from expm1 of I_x's series, not 1 - I_x.
    expect(relative(described_class.t_quantile(0.5 + 1e-12, 2e-12), 1.6619371919529144e-06)).to be < 1e-10
  end

  it "reads t's upper tail within 1e-10 relative, at large degrees of freedom too" do
    { [2.0, 1e6] => 0.022750266925659603, [5.0, 9.99e6] => 2.866564085871678e-07,
      [1.96, 30] => 0.02967115644802524, [40.0, 3] => 1.7190340394579263e-05,
      [4.0, 1e6] => 3.167351700502405e-05, [1e-8, 1e7] => 0.4999999960105773,
      [0.5, 0.05] => 0.4632750330425401, [3.0, 1e5] => 0.0013502304420323595 }.each do |(t, df), expected|
      expect(relative(described_class.t_sf(t, df), expected)).to be < 1e-10, "t #{t} df #{df}"
    end
  end

  it "matches SciPy's regularized incomplete beta at every fixture point, with its edges" do
    reference["incomplete_beta"].each do |x, a, b, expected|
      expect(relative(described_class.incomplete_beta(x, a, b), expected)).to be < 1e-9, [x, a, b].inspect
    end
    expect(described_class.incomplete_beta(0, 2, 3)).to eq(0.0)
    expect(described_class.incomplete_beta(1, 2, 3)).to eq(1.0)
  end

  it "converges within its bounded iterations up to 5,000,000 degrees of freedom" do
    [1, 30, 1_000, 100_000, 5_000_000].each do |df|
      [0.5, 2.0, 4.0].each do |t|
        expect(described_class.incomplete_beta(df / (df + (t * t)), df / 2.0, 0.5)).to be_between(0, 1)
      end
    end
  end

  it "keeps a beta quantile near q = 1 to its digits, by solving on the complement" do
    expect(relative(described_class.beta_quantile(1 - 1e-12, 1, 27.5), 0.6338694109920062)).to be < 1e-12
  end

  it "gives the beta posterior's quantiles at the largest shapes the interface reaches" do
    { 250_001.0 => [0.49861410091643216, 0.5013858990835678],
      500_001.0 => [0.499020019683853, 0.500979980316147] }.each do |shape, (lower, upper)|
      expect(relative(described_class.beta_quantile(0.025, shape, shape), lower)).to be < 1e-12
      expect(relative(described_class.beta_quantile(0.975, shape, shape), upper)).to be < 1e-12
    end
  end

  it "never raises on a valid beta quantile over the reviewer's grid, and inverts q = 1e-300 at shapes from 10" do
    shapes = [0.05, 0.1, 0.5, 1, 1.5, 2, 3.7, 10, 27.5, 100, 1000, 1e4, 1e5, 3e5]
    levels = [1e-300, 1e-100, 1e-20, 1e-12, 1e-6, 0.001, 0.025, 0.1, 0.3, 0.5, 0.7, 0.9, 0.975, 0.999,
              1 - 1e-6, 1 - 1e-12]
    shapes.product(shapes, levels).each do |a, b, q|
      expect(described_class.beta_quantile(q, a, b)).to be_between(0, 1), [q, a, b].inspect
    end
    shapes.select { _1 >= 10 }.product([0.05, 3.7, 1000]).each do |a, b|
      x = described_class.beta_quantile(1e-300, a, b)
      expect(relative(described_class.incomplete_beta(x, a, b), 1e-300)).to be < 1e-9, [a, b].inspect
    end
  end

  it "matches SciPy's beta quantile at every fixture point, with its edges" do
    reference["beta_quantile"].each do |q, a, b, expected|
      expect(relative(described_class.beta_quantile(q, a, b), expected)).to be < 1e-9, [q, a, b].inspect
    end
    expect(described_class.beta_quantile(0, 2, 3)).to eq(0.0)
    expect(described_class.beta_quantile(1, 2, 3)).to eq(1.0)
  end

  it "reads t's distribution function both ways, the upper tail directly" do
    expect(described_class.t_cdf(0, 5)).to eq(0.5)
    expect(described_class.t_cdf(-2.0, 9) + described_class.t_cdf(2.0, 9)).to be_within(1e-15).of(1.0)
    expect(described_class.t_cdf(described_class.t_quantile(0.975, 30), 30)).to be_within(1e-12).of(0.975)
    expect(described_class.t_sf(40.0, 3)).to be < 1e-4
  end

  it "refuses inputs outside each function's domain before any work" do
    [0, 1, -0.1, 1.5, Float::NAN, "0.5", nil].each do |p|
      expect { described_class.normal_quantile(p) }.to raise_error(ArgumentError)
      expect { described_class.t_quantile(p, 5) }.to raise_error(ArgumentError)
    end
    [0, -1, Float::INFINITY].each do |df|
      expect { described_class.t_quantile(0.9, df) }.to raise_error(ArgumentError)
      expect { described_class.t_cdf(1.0, df) }.to raise_error(ArgumentError)
    end
    expect { described_class.incomplete_beta(1.1, 2, 3) }.to raise_error(ArgumentError)
    expect { described_class.incomplete_beta(0.5, 0, 3) }.to raise_error(ArgumentError)
    expect { described_class.beta_quantile(-0.1, 2, 3) }.to raise_error(ArgumentError)
    expect { described_class.beta_quantile(0.5, 2, -3) }.to raise_error(ArgumentError)
  end
end
