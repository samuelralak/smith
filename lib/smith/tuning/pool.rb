# frozen_string_literal: true

module Smith
  module Tuning
    # Experimental. The candidates a tuning run keeps, each with its scores
    # on every validation sample (slice 5a design, section 1, rows 2, 3, 7
    # and 9).
    #
    # `pick` is the paper's Algorithm 2: for each validation sample, the
    # candidates with its best score; a candidate is dominated when the
    # samples it is best on are a strict subset of another's (the paper
    # gives no formal rule; strict subsets are transitive, so pruning at
    # once equals pruning in turns); one undominated candidate is drawn
    # with probability in proportion to how many samples it is best on,
    # by one draw below their sum, in index order. Winning samples are
    # bitsets: O(C N) to build, O(C^2 N / 64) to prune, O(C) to draw.
    #
    # `component` and `next_component` are the rotation, per candidate (the
    # paper's SelectModule takes the candidate): each keeps a pointer into
    # the component order, moved on each time a child of it is asked for
    # (not after a perfect minibatch, as in DSPy's run); a child starts
    # after the component that made it. `best` is the highest validation
    # mean, ties to the lowest index.
    #
    # A restored run rebuilds a pool by adding its candidates again and
    # moving each recorded parent's pointer.
    class Pool
      attr_reader :components, :validation_ids

      def initialize(components:, validation_ids:)
        @components = components.freeze
        @validation_ids = validation_ids.freeze
        @candidates = []
        @rows = []
        @pointers = []
      end

      # Adds a candidate with its validation scores ({sample id => 0..1}, one
      # for every validation sample); its index.
      def add(candidate, scores)
        row = validation_ids.map { scores[_1] }
        unless scores.size == row.size && row.all? { score?(_1) }
          raise ArgumentError, "a candidate joins the pool with a score from 0 to 1 for every validation sample"
        end

        @candidates << candidate
        @rows << row.map(&:to_f).freeze
        @pointers << start(candidate)
        @candidates.size - 1
      end

      def size = @candidates.size
      def empty? = @candidates.empty?
      def [](index) = @candidates.fetch(index)
      def candidates = @candidates.dup.freeze
      def scores(index) = @rows.fetch(index)
      def mean(index) = scores(index).sum / validation_ids.size

      # The undominated candidates, each with how many samples it is best
      # on, in index order.
      def frontier
        wins = winning_sets
        wins.each_with_index.with_object({}) do |(own, index), counts|
          next if own.zero? || wins.any? { |other| other.allbits?(own) && other != own }

          counts[index] = own.to_s(2).count("1")
        end
      end

      # A parent's index, drawn from `rng` (the run's SplitMix64).
      def pick(rng)
        counts = frontier
        drawn = rng.below(counts.values.sum)
        counts.each do |index, count|
          return index if drawn < count

          drawn -= count
        end
      end

      # The component a parent's child rewrites next.
      def component(index) = components[@pointers.fetch(index)]

      # That component; moves the parent's pointer on.
      def next_component(index)
        rewritten = component(index)
        @pointers[index] = (@pointers[index] + 1) % components.size
        rewritten
      end

      def best = (0...size).max_by { [mean(_1), -_1] }

      private

      def score?(value) = value.is_a?(Numeric) && value.real? && value.between?(0, 1)

      # The seed rotates from the first component, a child from the one after
      # the component that made it.
      def start(candidate)
        candidate.component ? (components.index(candidate.component) + 1) % components.size : 0
      end

      # Each candidate's winning samples as a bitset over validation order.
      def winning_sets
        wins = Array.new(size, 0)
        validation_ids.each_index do |sample|
          top = @rows.map { _1[sample] }.max
          @rows.each_with_index { |row, index| wins[index] |= (1 << sample) if row[sample] == top }
        end
        wins
      end
    end
  end
end
