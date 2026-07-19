# frozen_string_literal: true

RSpec.describe Smith::ExponentialBackoff do
  def build_schedule(**options)
    described_class.new(
      attempts: 4,
      base_delay: 0.5,
      max_delay: nil,
      jitter: 0,
      **options
    )
  end

  it "calculates exponential delays in constant space" do
    schedule = build_schedule

    expect((1...schedule.attempts).map { |attempt| schedule.delay(attempt) }).to eq([0.5, 1.0, 2.0])
  end

  it "caps before exponentiation would overflow" do
    schedule = build_schedule(attempts: 100, base_delay: Float::MAX, max_delay: 1.0)

    expect(schedule.delay(99)).to eq(1.0)
  end

  it "rejects an uncapped schedule that cannot remain finite" do
    expect do
      build_schedule(attempts: 100, base_delay: Float::MAX)
    end.to raise_error(ArgumentError, /finite numeric range/)
  end

  it "rejects finite delays outside the supported sleep interval" do
    expect do
      build_schedule(attempts: 2, base_delay: 3_000_000_000.0)
    end.to raise_error(ArgumentError, /supported sleep interval/)
  end

  it "rejects non-finite delay controls" do
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |value|
      expect { build_schedule(base_delay: value) }.to raise_error(ArgumentError, /finite and non-negative/)
      expect { build_schedule(jitter: value) }.to raise_error(ArgumentError, /finite and non-negative/)
      expect { build_schedule(max_delay: value) }.to raise_error(ArgumentError, /finite and non-negative/)
    end
  end

  it "normalizes numeric coercion range failures" do
    expect do
      build_schedule(base_delay: Complex(1, 1))
    end.to raise_error(ArgumentError, /finite and non-negative/)
  end

  it "rejects attempt counts beyond the configured bound" do
    expect do
      build_schedule(attempts: 101)
    end.to raise_error(ArgumentError, /must not exceed 100/)
  end

  it "adds jitter without exceeding a configured cap" do
    schedule = build_schedule(base_delay: 0.75, max_delay: 1.0, jitter: Float::MAX)

    expect(schedule.delay(1, random: -> { 0.5 })).to eq(1.0)
  end

  it "accepts the exact supported sleep boundary" do
    schedule = build_schedule(
      attempts: 2,
      base_delay: described_class::MAX_SLEEP_INTERVAL_SECONDS
    )

    expect(schedule.delay(1)).to eq(described_class::MAX_SLEEP_INTERVAL_SECONDS)
  end

  it "normalizes invalid custom random sources" do
    schedule = build_schedule(jitter: 0.5)

    [nil, Object.new, Complex(1, 1)].each do |invalid|
      expect { schedule.delay(1, random: -> { invalid }) }
        .to raise_error(ArgumentError, /random value must be finite/)
    end
  end
end
