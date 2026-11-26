# frozen_string_literal: true

require "smith/tuning"

# Minibatches (slice 5a design, section 1, row 4): the next b training ids
# of a shuffle drawn from the run's one generator, epoch by epoch, without
# replacement; a tail shorter than b starts the next epoch. The cursor and
# the generator's state, as an iteration line saves them, continue the
# same sequence.
RSpec.describe Smith::Tuning::Minibatches do
  let(:train) { Array.new(10) { format("t-%02d", _1) } }

  def generator(seed = 0) = Smith::Evals::Statistics::SplitMix64.new(seed)

  def draws(batches, rng, count) = Array.new(count) { batches.next(rng) }

  it "draws b distinct training ids at a time, each once an epoch, a short tail starting the next" do
    batches = described_class.new(train, size: 3)
    rng = generator
    drawn = draws(batches, rng, 3)

    expect(drawn).to all(have_attributes(size: 3))
    expect(drawn.flatten.uniq.size).to eq(9)
    expect(drawn.flatten - train).to eq([])
    expect(batches.cursor).to eq("epoch" => 0, "position" => 9)
    fourth = batches.next(rng)
    expect(batches.cursor).to eq("epoch" => 1, "position" => 3)
    expect(fourth.uniq.size).to eq(3)
    expect((fourth + draws(batches, rng, 2).flatten).uniq.size).to eq(9)
    expect(batches.cursor).to eq("epoch" => 1, "position" => 9)
  end

  # The pilot's case: b divides n, so each epoch's last minibatch is whole.
  it "draws every id once an epoch when the minibatch divides the training set (150 and 3)" do
    ids = Array.new(150) { format("t-%03d", _1) }
    batches = described_class.new(ids, size: 3)
    rng = generator(0)
    epoch = draws(batches, rng, 50)

    expect(epoch.flatten.sort).to eq(ids)
    expect(batches.cursor).to eq("epoch" => 0, "position" => 150)
    batches.next(rng)
    expect(batches.cursor).to eq("epoch" => 1, "position" => 3)
  end

  it "draws the same under one seed and other minibatches under another" do
    first = draws(described_class.new(train, size: 3), generator(0), 6)

    expect(draws(described_class.new(train, size: 3), generator(0), 6)).to eq(first)
    expect(draws(described_class.new(train, size: 3), generator(1), 6)).not_to eq(first)
    expect(first.flatten.tally.values.max).to be <= 2
  end

  # A restored run rebuilds its minibatches from the last line's cursor,
  # the ids its lines drew, and the generator's saved state.
  it "continues the same sequence when restored from its cursor, the ids drawn and the generator's state" do
    batches = described_class.new(train, size: 3)
    rng = generator(7)
    drawn = draws(batches, rng, 4)
    saved = [batches.cursor, rng.to_hex]
    later = draws(batches, rng, 5)

    restored = described_class.restore(train, size: 3, cursor: saved.first, drawn: drawn.flatten)
    expect(saved.first).to eq("epoch" => 1, "position" => 3)
    expect(draws(restored, Smith::Evals::Statistics::SplitMix64.from_hex(saved.last), 5)).to eq(later)
    expect(restored.cursor).to eq(batches.cursor)
  end

  it "refuses a minibatch larger than the training set, and a cursor its draws do not fit" do
    expect { described_class.new(train.first(2), size: 3) }.to raise_error(ArgumentError, /minibatch of 3.*2 training/)
    expect { described_class.restore(train, size: 3, cursor: { "epoch" => 0, "position" => 4 }, drawn: %w[t-00]) }
      .to raise_error(ArgumentError, /cursor/)
    expect { described_class.restore(train, size: 3, cursor: { "epoch" => 0, "position" => 1 }, drawn: %w[x-1]) }
      .to raise_error(ArgumentError, /cursor/)
  end
end
