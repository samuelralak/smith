# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      Sample = Data.define(:id, :trials, :cluster)

      # One sample: its id, its trial results (true or false, or scores in
      # 0..1, kept as Floats), and an optional cluster key for samples that
      # are not independent (two tickets from one customer).
      class Sample
        def initialize(id:, trials:, cluster: nil)
          super(id: Inputs.text!(id, "a sample id"), trials: Inputs.trials!(trials),
                cluster: cluster.nil? ? nil : Inputs.text!(cluster, "a cluster key"))
        end
      end

      # A reducer: how one sample's trials become its value.
      Reducer = Data.define(:name, :kind, :k)
      class Reducer
        VOTES = %i[majority any all].freeze

        def binary? = VOTES.include?(kind)
        def bootstrap? = %i[pass_at pass_all].include?(kind)

        def value(trials)
          return trials.sum { |trial| number(trial) } / trials.size if kind == :mean

          passed = trials.count(true)
          return Formulas.public_send(kind, n: trials.size, c: passed, k:) if bootstrap?

          vote(passed, trials.size)
        end

        # The value as an exact number, so equality is decided exactly: a
        # mean of pass/fail trials and pass@k or pass^k as Rationals, a score
        # as its Float's exact value, a vote as it is.
        def exact(trials)
          return Rational(value(trials)) if kind == :mean && !trials.all? { |trial| [true, false].include?(trial) }
          return Rational(trials.count(true), trials.size) if kind == :mean
          return exact_pass(trials.size, trials.count(true)) if bootstrap?

          value(trials)
        end

        private

        # 1 - C(n - c, k)/C(n, k) for pass@k, C(c, k)/C(n, k) for pass^k.
        def exact_pass(size, passed)
          return Rational(choose(passed, k), choose(size, k)) if kind == :pass_all

          1 - Rational(choose(size - passed, k), choose(size, k))
        end

        def choose(total, part)
          return 0 if part > total

          (1..part).reduce(1) { |product, index| product * (total - part + index) / index }
        end

        def number(trial)
          return trial if trial.is_a?(Float)

          trial ? 1.0 : 0.0
        end

        def vote(passed, size)
          case kind
          when :majority then 2 * passed > size ? 1 : 0
          when :any then passed.positive? ? 1 : 0
          else passed == size ? 1 : 0
          end
        end
      end
      private_constant :Reducer

      # What an estimate measures and how: the reducer, the scale, the
      # level, and the bootstrap's settings.
      Request = Data.define(:reducer, :scale, :confidence, :resamples, :threshold, :seed)
      class Request
        def self.at(reducer, scale, confidence)
          new(reducer:, scale:, confidence:, resamples: RESAMPLES, threshold: 30, seed: nil)
        end
      end
      private_constant :Request
    end
  end
end
