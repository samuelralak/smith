# frozen_string_literal: true

require "smith/tuning"

# The given split (slice 5a design, section 1, row 0): training and
# validation as two narrowings of the suite's selection, which never share
# a sample; at least 10 training and 30 validation samples unless an
# override, which the header records, says otherwise.
RSpec.describe Smith::Tuning::Split do
  let(:at) { Time.utc(2026, 11, 26, 9, 30, 1.25r) }
  let(:samples) do
    train = Array.new(12) { line(format("q-%03d", _1), "train") }
    val = Array.new(31) { line(format("q-%03d", _1 + 100), "val") }
    (train + val + [line("q-900", "other")]).sort_by { _1["id"] }.map { Smith::Evals::Sample.new(_1, split: :dev) }
  end

  def line(id, tag) = { "id" => id, "input" => id, "tags" => [tag] }

  def given(train: { tags_any: ["train"] }, validation: { tags_any: ["val"] }, override: nil)
    described_class.given(samples, train:, validation:, override:, at:)
  end

  it "selects each part by its narrowing, in the selection's order, and writes the header's split" do
    split = given

    expect(split.train_ids).to eq(Array.new(12) { format("q-%03d", _1) })
    expect(split.validation_ids).to eq(Array.new(31) { format("q-%03d", _1 + 100) })
    expect(split.to_h).to eq(
      "rule" => "given",
      "train" => { "count" => 12, "ids_digest" => Smith::Evals::Identity.sample_ids_digest(split.train_ids) },
      "validation" => { "count" => 31,
                        "ids_digest" => Smith::Evals::Identity.sample_ids_digest(split.validation_ids) },
      "ratio" => nil, "override" => nil
    )
    expect([split, split.train_ids, split.validation_ids]).to all(be_frozen)
  end

  it "selects by ids too, in the selection's order whatever order they are given in" do
    ids = Array.new(10) { format("q-%03d", 9 - _1) }
    split = given(train: { ids: })

    expect(split.train_ids).to eq(ids.sort)
  end

  it "refuses parts that share a sample, since a validation sample must never reach a reflection" do
    expect { given(train: { tags_any: %w[train val] }) }
      .to raise_error(Smith::Tuning::SplitRefused, /31 samples are in both/)
  end

  it "refuses an id the suite's selection does not hold" do
    expect { given(train: { ids: %w[q-000 nope] }) }
      .to raise_error(Smith::Tuning::SplitRefused, /train names nope, which the suite does not select/)
  end

  it "refuses fewer than 10 training or 30 validation samples unless overridden, and records the override" do
    small = { ids: Array.new(9) { format("q-%03d", _1) } }
    actor = Smith::Evals::Actor.person("usr_51a8")

    expect { given(train: small) }.to raise_error(Smith::Tuning::SplitRefused, /train has 9 samples.*at least 10/)
    expect { given(validation: { ids: %w[q-100] }) }
      .to raise_error(Smith::Tuning::SplitRefused, /validation has 1 sample.*at least 30/)
    split = given(train: small, override: { actor:, reason: "a first look" })
    expect(split.train_ids.size).to eq(9)
    expect(split.to_h["override"])
      .to eq("actor" => actor.to_h, "reason" => "a first look", "at" => "2026-11-26T09:30:01.250Z")
  end

  # Plan 4.4 and 5.3: the tuner's sets come out of dev, enforced by the tool.
  it "refuses a selection holding samples outside the dev split" do
    { holdout: "31 samples are in the holdout split", calibration: "1 sample is in the calibration split" }
      .each do |split, words|
      chosen = split == :holdout ? samples.select { _1.tags == ["val"] }.map(&:to_h) : [samples.first.to_h]
      mixed = samples.map { chosen.include?(_1.to_h) ? Smith::Evals::Sample.new(_1.to_h, split:) : _1 }

      expect do
        described_class.given(mixed, train: { tags_any: ["train"] }, validation: { tags_any: ["val"] },
                                     override: nil, at:)
      end
        .to raise_error(Smith::Tuning::SplitRefused, /#{words}; a tuning run takes dev samples only/)
    end
  end

  it "takes a sample when any one of its tags is wanted" do
    tagged = samples.map do |sample|
      next sample unless sample.tags == ["train"]

      Smith::Evals::Sample.new(sample.to_h.merge("tags" => %w[x train]), split: :dev)
    end

    expect(described_class.given(tagged, train: { tags_any: ["train"] }, validation: { tags_any: ["val"] },
                                         override: nil, at:).train_ids.size).to eq(12)
  end

  it "lets an override lift the validation minimum too" do
    actor = Smith::Evals::Actor.person("usr_51a8")

    expect(given(validation: { ids: %w[q-100] }, override: { actor:, reason: "r" }).validation_ids).to eq(%w[q-100])
  end

  it "refuses a part that selects nothing, override or not" do
    expect { given(train: { tags_any: ["none"] }, override: { actor: Smith::Evals::Actor.person("u"), reason: "r" }) }
      .to raise_error(Smith::Tuning::SplitRefused, /train selects no sample/)
  end
end
