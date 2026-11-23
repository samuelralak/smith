# frozen_string_literal: true

require "smith/evals"

# The split rule of slice-1a design 8.3: integer thresholds from each share's
# decimal spelling, a bucket from the first 8 bytes of a framed SHA-256 over
# the seed and the sample's cluster key (or its id), so every language agrees.
RSpec.describe Smith::Evals::SplitRule do
  let(:rule) { described_class.new(seed: "support-tickets-2026-11", holdout: 0.25, calibration: 0.05) }

  it "computes its thresholds exactly from the shares' decimal spelling, never in Float arithmetic" do
    expect(rule.thresholds).to eq([4_611_686_018_427_387_904, 5_534_023_222_112_865_484])
    # 0.1 * 2**64 in Floats is 1844674407370955264; the exact value floors to ...161.
    expect(described_class.new(seed: "s", holdout: 0.1, calibration: 0.0).thresholds)
      .to eq([1_844_674_407_370_955_161, 1_844_674_407_370_955_161])
    expect(described_class.new(seed: "s", holdout: 1, calibration: 0).thresholds).to eq([2**64, 2**64])
  end

  it "takes the bucket from SHA-256 of the framed seed and cluster, or id when there is no cluster" do
    bucket = ->(key) { Digest::SHA256.digest("smith.evals.split/1\n#{key}")[0, 8].unpack1("Q>") }
    by_cluster = bucket.call(%({"cluster":"cus-1","seed":"s"}))
    by_id = bucket.call(%({"id":"t-1","seed":"s"}))
    plain = described_class.new(seed: "s", holdout: 0.5, calibration: 0.0)

    expect(plain.bucket(id: "t-1", cluster: "cus-1")).to eq(by_cluster)
    expect(plain.bucket(id: "t-2", cluster: "cus-1")).to eq(by_cluster)
    expect(plain.bucket(id: "t-1", cluster: nil)).to eq(by_id)
  end

  it "assigns holdout below the first threshold, calibration below the second, dev above" do
    buckets = [(2**63) - 1, 2**63, (3 * (2**62)) - 1, 3 * (2**62)]
    edges = Class.new(described_class) { define_method(:bucket) { |**| buckets.shift } }
                 .new(seed: "s", holdout: 0.5, calibration: 0.25)

    expect(Array.new(4) { edges.assign(id: "x", cluster: nil) }).to eq(%w[holdout calibration calibration dev])
  end

  it "takes an ASCII seed in any encoding as UTF-8, and writes a negative zero share as 0" do
    rule = described_class.new(seed: "s".b, holdout: -0.0, calibration: 0)

    expect([rule.seed.encoding, rule.to_h["shares"]])
      .to eq([Encoding::UTF_8, { "holdout" => 0.0, "calibration" => 0.0 }])
    expect(1 / rule.holdout).to eq(Float::INFINITY)
  end

  it "writes and reads its manifest form" do
    expect(rule.to_h).to eq("method" => "hash_threshold", "seed" => "support-tickets-2026-11", "key" => "cluster_or_id",
                            "shares" => { "holdout" => 0.25, "calibration" => 0.05 })
    expect(described_class.from_h(rule.to_h).thresholds).to eq(rule.thresholds)
  end

  it "refuses shares outside 0..1 or summing past 1, a bad seed, and another method or key" do
    expect { described_class.new(seed: "s", holdout: 0.7, calibration: 0.4) }.to raise_error(ArgumentError, /at most 1/)
    expect { described_class.new(seed: "s", holdout: -0.1, calibration: 0) }.to raise_error(ArgumentError, /holdout/)
    expect { described_class.new(seed: "s", holdout: Float::NAN, calibration: 0) }.to raise_error(ArgumentError)
    expect { described_class.new(seed: "s", holdout: true, calibration: 0) }.to raise_error(ArgumentError)
    expect { described_class.new(seed: "", holdout: 0, calibration: 0) }.to raise_error(ArgumentError, /seed/)
    expect { described_class.new(seed: "\xFF".b, holdout: 0, calibration: 0) }.to raise_error(ArgumentError, /seed/)
    expect { described_class.from_h(rule.to_h.merge("method" => "random")) }
      .to raise_error(ArgumentError, /hash_threshold/)
    expect { described_class.from_h(rule.to_h.merge("key" => "id")) }.to raise_error(ArgumentError, /cluster_or_id/)
  end
end
