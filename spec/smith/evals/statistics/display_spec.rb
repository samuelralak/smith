# frozen_string_literal: true

require "json"
require "smith/evals/statistics"

RSpec.describe Smith::Evals::Statistics::Display do
  reference = JSON.parse(File.read(File.expand_path("../../../fixtures/evals/statistics_reference.json", __dir__)))
  statistics = Smith::Evals::Statistics

  it "rounds half away from zero on the decimal value, as every display_rounding case reads" do
    reference["display_rounding"]["cases"].each do |row|
      text = if row.first == "points"
               described_class.text(row[1], unit: "points", decimals: 1, signed: true)
             else
               described_class.text(row[0], unit: "percent", decimals: 0)
             end
      expect(text).to eq(row.last), row.inspect
    end
  end

  it "shows 0.725 as 73 though its double is slightly below 0.725" do
    expect(0.725.to_r).to be < Rational(725, 1000)
    expect(described_class.text(0.725, unit: "percent", decimals: 0)).to eq("73")
    expect(described_class.text(0.735, unit: "percent", decimals: 0)).to eq("74")
  end

  it "never pins a value strictly inside 0..1 at the end of the scale, as every display_never_pinned case reads" do
    reference["display_never_pinned"]["cases"].each do |row|
      display = described_class.estimate(point: row["point"], lower: row["lower"], upper: row["upper"], unit: "percent")
      expect(display).to eq(row["display"]), row.inspect
    end
  end

  it "shows a bound of 0.9953 as 99.5, never 100, and an exact 37 of 37 as 100" do
    display = described_class.estimate(point: 0.972972972972973, lower: 0.8576, upper: 0.9953, unit: "percent")
    expect(display.values_at("point", "lower", "upper")).to eq(%w[97.3 85.8 99.5])

    all = statistics.rate(successes: 37, total: 37).display
    expect(all.values_at("decimals", "point", "upper")).to eq([0, "100", "100"])
  end

  it "gives the screens' examples their numbers" do
    { [21, 23] => %w[91 73 98], [27, 30] => %w[90 74 97], [52, 60] => %w[87 76 93], [55, 58] => %w[95 86 98] }
      .each do |(successes, total), shown|
        display = statistics.rate(successes:, total:).display
        expect(display.values_at("point", "lower", "upper")).to eq(shown), "#{successes} of #{total}"
      end
  end

  it "adds decimals when a bound that decides a verdict would round onto its threshold" do
    bounds = { "point" => 0.02, "lower" => 0.0004, "upper" => 0.04 }
    better = described_class.difference(bounds, verdict: "better", margin: 0.0, unit: "points")
    expect(better).to eq("unit" => "points", "decimals" => 2, "point" => "+2.00", "lower" => "+0.04",
                         "upper" => "+4.00")

    bounds = { "point" => -0.02, "lower" => -0.04, "upper" => -0.00004 }
    worse = described_class.difference(bounds, verdict: "worse", margin: 0.0, unit: "points")
    expect(worse.values_at("decimals", "upper")).to eq([3, "-0.004"])

    bounds = { "point" => 0.075, "lower" => 0.014926603950636157, "upper" => 0.13938784672990062 }
    plain = described_class.difference(bounds, verdict: "better", margin: 0.0, unit: "points")
    expect(plain.values_at("decimals", "point", "lower", "upper")).to eq([1, "+7.5", "+1.5", "+13.9"])
  end

  it "shows scores to two decimals, and a zero difference unsigned" do
    expect(described_class.estimate(point: 0.6742, lower: 0.6066, upper: 0.7418, unit: "score"))
      .to eq("unit" => "score", "decimals" => 2, "point" => "0.67", "lower" => "0.61", "upper" => "0.74")
    expect(described_class.text(0.0, unit: "points", decimals: 1, signed: true)).to eq("0.0")
    expect(described_class.text(-0.0004, unit: "points", decimals: 1, signed: true)).to eq("0.0")
  end

  it "shows no numbers for no samples, and ranges as whole points or counts" do
    expect(described_class.estimate(point: nil, lower: nil, upper: nil, unit: "percent"))
      .to eq("unit" => "percent", "decimals" => 0, "point" => nil, "lower" => nil, "upper" => nil)
    expect(described_class.range({ "low" => 0.0852, "typical" => 0.1112, "high" => 0.1326 }, unit: "points"))
      .to eq("unit" => "points", "decimals" => 0, "low" => "9", "typical" => "11", "high" => "13")
    expect(described_class.range({ "low" => 275, "typical" => 455, "high" => 634 }, unit: "count"))
      .to eq("unit" => "count", "decimals" => 0, "low" => "275", "typical" => "455", "high" => "634")
  end
end
