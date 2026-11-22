# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # Checks of single values.
      module Inputs
        REDUCER = /\A(?:(majority|any|all|mean)|pass_(at|all)_([1-9][0-9]?))\z/
        SCALES = %w[binary continuous].freeze

        class << self
          def text!(value, name)
            text = value.is_a?(Symbol) ? value.name : value
            raise ArgumentError, "#{name} is a non-empty String of UTF-8" unless text.is_a?(String) && utf8?(text)

            text.frozen? && text.encoding == Encoding::UTF_8 ? text : text.dup.force_encoding(Encoding::UTF_8).freeze
          end

          def trials!(trials)
            unless trials.is_a?(Array) && trials.size <= MAX_TRIALS
              raise ArgumentError, "a sample's trials are an Array of at most #{MAX_TRIALS}"
            end

            trials.map { |trial| trial!(trial) }.freeze
          end

          def reducer!(value)
            match = REDUCER.match(value.is_a?(Symbol) ? value.name : value.to_s)
            unless match
              raise ArgumentError, "reducer is majority, any, all, mean, pass_at_<k> or pass_all_<k> (k from 1 to 99)"
            end

            return Reducer.new(name: match[1], kind: match[1].to_sym, k: nil) if match[1]

            Reducer.new(name: match[0], kind: :"pass_#{match[2]}", k: Integer(match[3], 10))
          end

          def scale!(value, reducer)
            scale = value.to_s
            raise ArgumentError, "scale is :binary or :continuous" unless SCALES.include?(scale)
            return scale unless scale == "continuous" && reducer.kind != :mean

            raise ArgumentError, "a continuous scale takes the mean reducer"
          end

          def level!(value, name)
            return value.to_f if real?(value) && value.positive? && value < 1

            raise ArgumentError, "#{name} is strictly between 0 and 1"
          end

          # A confidence every level read from it can take (MAX_CONFIDENCE).
          def confidence!(value)
            return value.to_f if real?(value) && value.positive? && value <= MAX_CONFIDENCE

            raise ArgumentError, "confidence is a number above 0 and at most #{MAX_CONFIDENCE}"
          end

          def count!(value, name, minimum: 1)
            return value if value.is_a?(Integer) && value.between?(minimum, CanonicalJSON::MAX_SAFE_INTEGER)

            raise ArgumentError, "#{name} is an Integer of at least #{minimum}"
          end

          def margin!(value)
            raise ArgumentError, "margin is a number of at least 0" unless real?(value) && value >= 0

            value.to_f
          end

          def no_worse_margin!(value)
            return if value.nil?
            raise ArgumentError, "no_worse_margin is nil or a number above 0" unless real?(value) && value.positive?

            value.to_f
          end

          # A caller's seed, recorded as 16 hex digits.
          def seed!(value)
            return if value.nil?
            return SplitMix64.from_hex(value) && value unless value.is_a?(Integer)

            SplitMix64.new(value) # refuses a seed outside 64 bits
            format("%016x", value)
          end

          def real?(value)
            value.is_a?(Numeric) && value.real? && value.to_f.finite?
          end

          private

          def trial!(trial)
            return trial if [true, false].include?(trial)
            return trial.to_f if real?(trial) && trial.between?(0, 1)

            raise ArgumentError, "a trial is true, false or a number in 0..1"
          end

          def utf8?(text)
            !text.empty? && ((text.encoding == Encoding::UTF_8 && text.valid_encoding?) || text.ascii_only?)
          end
        end
      end
      private_constant :Inputs
    end
  end
end
