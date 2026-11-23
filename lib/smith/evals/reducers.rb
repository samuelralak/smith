# frozen_string_literal: true

module Smith
  module Evals
    # Experimental. The named reducers (slice-1a design, 4.4): how a
    # sample's counted trials (m of them, c passed) become its value, and
    # the names records give them. majority passes when 2c > m (a tie
    # fails); any when c >= 1; all when c == m; mean is c/m, or the mean
    # value on the continuous scale; pass_at_<k> and pass_all_<k> are the
    # unbiased estimators of passing at least once, and every time, in k
    # (they need m >= k). The statistics module reads the same names. O(m)
    # per sample (pass@k and pass^k O(m + k), in Rationals until the end).
    module Reducers
      NAME = /\A(?:majority|any|all|mean|pass_(?:at|all)_[1-9][0-9]?)\z/
      VOTES = %w[majority any all].freeze

      class << self
        # The record's name for :majority, "pass_at_2", { pass_at: 2 }, ...
        def name_of(reducer)
          name = case reducer
                 when Symbol, String then reducer.to_s
                 when Hash then estimator_name(reducer)
                 end
          return name if name && NAME.match?(name)

          raise ArgumentError, "a reducer is majority, any, all, mean, or pass_at: k or pass_all: k (k from 1 to 99)"
        end

        # k for pass_at_<k> and pass_all_<k>; nil for the others.
        def k(name) = name_of(name)[/\Apass_(?:at|all)_(\d+)\z/, 1]&.to_i

        # mean fits both scales; every other reducer only the binary one.
        def fits?(name, scale) = name_of(name) == "mean" || scale.to_s == "binary"

        def value(name, trials)
          name = name_of(name)
          counted = trials!(trials, name)
          return mean(counted) if name == "mean"

          passed = counted.count(true)
          return vote(name, passed, counted.size) if VOTES.include?(name)

          estimator(name, passed, counted.size).to_f
        end

        private

        def estimator_name(reducer)
          return unless reducer.size == 1

          kind, k = reducer.first
          "#{kind}_#{k}" if %w[pass_at pass_all].include?(kind.to_s) && k.is_a?(Integer)
        end

        def trials!(trials, name)
          unless trials.is_a?(Array) && !trials.empty?
            raise ArgumentError, "a sample's value needs at least one counted trial"
          end

          return trials if trials.all? { [true, false].include?(_1) }
          raise ArgumentError, "#{name} reduces trials that are true or false" unless name == "mean"
          return trials if trials.all? { score?(_1) }

          raise ArgumentError, "mean reduces trials all true or false, or all values from 0 to 1"
        end

        def score?(trial) = trial.is_a?(Numeric) && trial.real? && trial.between?(0, 1)

        # In Floats, as the statistics module reduces a mean.
        def mean(trials)
          return trials.count(true).to_f / trials.size if [true, false].include?(trials.first)

          trials.sum(&:to_f) / trials.size
        end

        def vote(name, passed, size)
          won = case name
                when "majority" then 2 * passed > size
                when "any" then passed >= 1
                else passed == size
                end
          won ? 1.0 : 0.0
        end

        # 1 - C(m - c, k)/C(m, k) for pass@k, C(c, k)/C(m, k) for pass^k.
        def estimator(name, passed, size)
          k = k(name)
          raise ArgumentError, "#{name} needs at least #{k} trials of a sample" if size < k
          return Rational(choose(passed, k), choose(size, k)) if name.start_with?("pass_all")

          1 - Rational(choose(size - passed, k), choose(size, k))
        end

        def choose(total, part)
          return 0 if part > total

          (1..part).reduce(1) { |product, index| product * (total - part + index) / index }
        end
      end
    end
  end
end
