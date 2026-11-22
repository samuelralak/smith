# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # One candidate's samples paired with the baseline's by id, read once
      # and evaluated at any level: O(n) to pair, O(1) an interval.
      class Pairing
        # [baseline, candidate] values: a both pass, b the candidate only, c
        # the baseline only, d neither.
        CELLS = { a: [1, 1], b: [0, 1], c: [1, 0], d: [0, 0] }.freeze

        attr_reader :baseline, :candidate, :point, :changed

        def initialize(baseline, candidate, reducer)
          @baseline_size = baseline.size
          @candidate_size = candidate.size
          by_id = candidate.to_h { |sample| [sample.id, sample] }
          @baseline = baseline.select { |sample| by_id.key?(sample.id) }
          @candidate = @baseline.map { |sample| by_id[sample.id] }
          @reducer = reducer
          read(values(@baseline, reducer), values(@candidate, reducer))
        end

        def size = @baseline.size
        def only_in_baseline = @baseline_size - size
        def only_in_candidate = @candidate_size - size
        def binary? = @reducer.binary?

        # [lower, upper] for candidate minus baseline at a level.
        def interval(level)
          return Formulas.newcombe(**@table, level:).drop(1) if binary?
          return [point, point] if @equal || @spread.zero?

          Formulas.t_interval(mean: point, sd: @spread, n: size, level:)
        end

        # The classic test beside the interval, which no verdict reads.
        def test
          return { "method" => "t_paired", "p_value" => t_p_value } unless binary?

          { "method" => "mcnemar_exact", "p_value" => Formulas.mcnemar_exact(b: @table[:b], c: @table[:c]) }
        end

        def warnings(threshold)
          warnings = []
          warnings << "unpaired_samples" if only_in_baseline.positive? || only_in_candidate.positive?
          warnings << "small_sample" if size < threshold
          warnings << "clusters_ignored" if shared_clusters?
          warnings << (binary? ? "zero_discordant" : "no_variation") if steady?
          warnings
        end

        private

        def values(samples, reducer) = samples.map { |sample| reducer.value(sample.trials) }

        def t_p_value
          return Formulas.t_test_p(point, @spread, size) unless @equal || @spread.zero?

          point.zero? ? 1.0 : 0.0
        end

        def shared_clusters?
          keys = @baseline.map { |sample| SampleList.cluster_key(sample) }
          keys.uniq.size < keys.size
        end

        # No paired sample changed (pass/fail), or no difference varied.
        def steady?
          binary? ? (@table[:b] + @table[:c]).zero? : @equal
        end

        def read(before, after)
          moves = after.zip(before).map { |now, was| now <=> was }
          @changed = { "better" => moves.count(1), "worse" => moves.count(-1), "same" => moves.count(0) }
          binary? ? read_table(before, after) : read_differences(before, after)
        end

        def read_table(before, after)
          raise ArgumentError, "a pass/fail comparison needs at least one paired sample" if size.zero?

          pairs = before.zip(after).tally
          @table = CELLS.transform_values { |cell| pairs.fetch(cell, 0) }
          @point = difference_of(@table)
        end

        # (a + b)/n - (a + c)/n, as the paired proportions' difference.
        def difference_of(table)
          (table[:a] + table[:b]).fdiv(size) - (table[:a] + table[:c]).fdiv(size)
        end

        def read_differences(before, after)
          raise ArgumentError, "a comparison of values needs at least two paired samples" if size < 2

          @equal = Formulas.equal_values?(exact_differences)
          @equal ? equal_differences : varied_differences(after.zip(before).map { |now, was| now - was })
        end

        def varied_differences(differences)
          @point = differences.sum.fdiv(size)
          @spread = Math.sqrt(differences.sum { |value| (value - @point)**2 } / (size - 1))
        end

        # Candidate minus baseline per pair, exactly, read only as far as the
        # first that differs.
        def exact_differences
          @candidate.each_index.lazy.map do |index|
            @reducer.exact(@candidate[index].trials) - @reducer.exact(@baseline[index].trials)
          end
        end

        # Every difference the same: that difference, with no spread.
        def equal_differences
          @point = exact_differences.first.to_f
          @spread = 0.0
        end
      end
      private_constant :Pairing
    end
  end
end
