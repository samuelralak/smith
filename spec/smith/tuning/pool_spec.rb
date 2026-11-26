# frozen_string_literal: true

require "smith/tuning"

# The pool (slice 5a design, section 1, rows 2, 3 and 9), on hand-made
# matrices: Algorithm 2's selection (each validation sample's best
# candidates; a candidate whose winning samples are a strict subset of
# another's pruned; a draw in proportion to how many samples each is best
# on, from the run's generator), rotation per candidate, and the best mean
# with ties to the lowest index.
RSpec.describe Smith::Tuning::Pool do
  let(:run) { "tu_#{"2" * 32}" }
  let(:components) { %w[a.predict b.predict c.predict] }
  let(:validation) { %w[v-0 v-1 v-2 v-3] }
  let(:seed) do
    prompts = components.to_h { [_1, Smith::Prompt.new(_1, "Do #{_1}.")] }
    Smith::Tuning::Candidate.seed(prompts, components: nil, tuning_run_id: run)
  end
  let(:pool) { described_class.new(components:, validation_ids: validation) }

  # A script of draws: below(n) answers the next value, and records n.
  let(:scripted) do
    Class.new do
      attr_reader :bounds

      def initialize(*values)
        @values = values
        @bounds = []
      end

      def below(bound)
        @bounds << bound
        @values.shift
      end
    end
  end

  def child(component, iteration, parent: 0)
    seed.child(component, "Do #{component} better #{iteration}.",
               iteration:, parent:)
  end

  def add(scores, candidate = nil)
    pool.add(candidate || child("a.predict", pool.size + 1), validation.zip(scores).to_h)
  end

  def generator(seed = 0) = Smith::Evals::Statistics::SplitMix64.new(seed)

  # Samples: v-0 best for 0 and 1, v-1 for 1 and 2, v-2 for all (all score
  # 0), v-3 for 0 and 3. Wins: 0 {0,2,3}, 1 {0,1,2}, 2 {1,2}, 3 {2,3}: 2 is a
  # strict subset of 1's, 3 of 0's.
  def paper_matrix
    pool.add(seed, validation.zip([1.0, 0.0, 0.0, 0.5]).to_h)
    add([1.0, 1.0, 0.0, 0.0])
    add([0.0, 1.0, 0.0, 0.0])
    add([0.0, 0.0, 0.0, 0.5])
  end

  describe "selection" do
    it "prunes a candidate whose winning samples are a strict subset of another's, counting the rest" do
      paper_matrix

      expect(pool.frontier).to eq(0 => 3, 1 => 3)
    end

    it "keeps candidates that win on the same samples, since neither is a strict subset" do
      paper_matrix
      add([1.0, 0.0, 0.0, 0.5])

      expect(pool.frontier).to eq(0 => 3, 1 => 3, 4 => 3)
    end

    # Fewer wins is not domination: A best on {v-0} and B on {v-1, v-2, v-3}
    # share no sample, so both stay.
    it "keeps a candidate that wins on fewer samples when they are not a subset of another's" do
      pool.add(seed, validation.zip([1.0, 0.0, 0.0, 0.5]).to_h)
      add([0.0, 1.0, 1.0, 1.0])

      expect(pool.frontier).to eq(0 => 1, 1 => 3)
    end

    it "counts a sample every candidate fails for every candidate, as the paper's best-score sets do" do
      pool.add(seed, validation.zip([0.0, 0.0, 0.0, 1.0]).to_h)
      add([0.0, 0.0, 0.0, 0.0])

      expect(pool.frontier).to eq(0 => 4)
    end

    it "draws in proportion to the counts, in index order, from one draw below their sum" do
      paper_matrix
      draws = scripted.new(0, 2, 3, 5)

      expect(Array.new(4) { pool.pick(draws) }).to eq([0, 0, 1, 1])
      expect(draws.bounds).to eq([6, 6, 6, 6])
    end

    it "repeats its draws under one seed, and draws each frontier candidate about as often as its count says" do
      paper_matrix
      add([0.0, 1.0, 0.0, 0.5]) # wins {1,2,3}: frontier 0 (3), 1 (3), 4 (3)
      first = Array.new(3_000) { pool.pick(generator(_1)) }
      picks = generator(11).then { |rng| Array.new(3_000) { pool.pick(rng) } }

      expect(Array.new(3_000) { pool.pick(generator(_1)) }).to eq(first)
      expect(picks.tally.keys.sort).to eq([0, 1, 4])
      expect(picks.tally.values).to all(be_between(900, 1_100))
    end

    it "picks the only candidate of a pool of one" do
      pool.add(seed, validation.zip([0.5, 0.5, 0.5, 0.5]).to_h)

      expect(pool.pick(generator)).to eq(0)
    end
  end

  describe "rotation" do
    it "keeps a pointer per candidate, moved each time it is picked as parent; a child starts after its component" do
      pool.add(seed, validation.zip([0.5] * 4).to_h)
      pool.add(child("b.predict", 1), validation.zip([0.5] * 4).to_h)

      expect(pool.next_component(0)).to eq("a.predict")
      expect(pool.next_component(1)).to eq("c.predict")
      expect(pool.next_component(0)).to eq("b.predict")
      expect(pool.next_component(1)).to eq("a.predict")
      expect(pool.next_component(0)).to eq("c.predict")
      expect(pool.next_component(0)).to eq("a.predict")
      expect(pool.next_component(1)).to eq("b.predict")
    end

    # A restored loop folds its lines: it adds the same candidates and moves
    # each recorded parent's pointer, and draws on from the saved generator.
    it "continues the same picks and components when rebuilt from what the lines record" do
      paper_matrix
      rng = generator(3)
      parents = Array.new(5) { pool.pick(rng).tap { |index| pool.next_component(index) } }
      saved = rng.to_hex
      later = Array.new(4) { pool.pick(rng).then { |index| [index, pool.next_component(index)] } }

      rebuilt = described_class.new(components:, validation_ids: validation)
      pool.candidates.each_with_index do |candidate, index|
        rebuilt.add(candidate, validation.zip(pool.scores(index)).to_h)
      end
      parents.each { rebuilt.next_component(_1) }
      restored = Smith::Evals::Statistics::SplitMix64.from_hex(saved)
      expect(Array.new(4) do
        rebuilt.pick(restored).then do |index|
          [index, rebuilt.next_component(index)]
        end
      end).to eq(later)
    end
  end

  describe "the best" do
    it "is the highest mean even when another candidate is best on more samples" do
      pool.add(seed, validation.zip([0.9, 0.9, 0.9, 0.9]).to_h)
      add([1.0, 1.0, 1.0, 0.0])

      expect([pool.best, pool.frontier]).to eq([0, { 0 => 1, 1 => 3 }])
    end

    it "is the highest validation mean, ties to the lowest index" do
      pool.add(seed, validation.zip([0.5, 0.5, 0.5, 0.5]).to_h)
      add([1.0, 1.0, 0.5, 0.5])
      add([1.0, 0.5, 1.0, 0.5])

      expect(pool.best).to eq(1)
      expect([pool.mean(0), pool.mean(1), pool.mean(2)]).to eq([0.5, 0.75, 0.75])
    end
  end

  it "keeps a candidate's scores in validation order, whatever order they come in" do
    pool.add(seed, validation.zip([0.1, 0.2, 0.3, 0.4]).to_h.to_a.reverse.to_h)

    expect(pool.scores(0)).to eq([0.1, 0.2, 0.3, 0.4])
  end

  it "takes a candidate only with a score in 0 to 1 for every validation sample" do
    [validation.first(3).zip([1.0] * 3).to_h, validation.zip([1.0] * 4).to_h.merge("v-9" => 1.0),
     validation.zip([1.0, 1.0, 1.0, 1.5]).to_h, validation.zip([1.0, 1.0, 1.0, nil]).to_h].each do |scores|
      expect { pool.add(seed, scores) }.to raise_error(ArgumentError, /score/), scores.inspect
    end
    expect(pool.size).to eq(0)
  end
end
