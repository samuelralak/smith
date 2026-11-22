# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # Checks of a list of samples, and how samples sort and cluster.
      module SampleList
        class << self
          # The samples with at least one trial, ids unique, in UTF-16 order
          # of their ids, each trial fit for the scale and reducer.
          def check!(value, name, reducer:, scale:)
            unless value.is_a?(Array) && value.size <= MAX_SAMPLES && value.all?(Sample)
              raise ArgumentError, "#{name} is an Array of at most #{MAX_SAMPLES} Statistics::Sample values"
            end

            unique!(value, name)
            counted = value.reject { |sample| sample.trials.empty? }
            counted.each { |sample| fits!(sample, reducer, scale) }
            counted.sort_by { |sample| utf16(sample.id) }
          end

          def bootstrap_work!(count, resamples)
            return if count * resamples <= MAX_BOOTSTRAP_WORK

            raise ArgumentError, "a bootstrap's work (resamples times samples) is at most #{MAX_BOOTSTRAP_WORK}"
          end

          # A sample with no cluster key is its own cluster.
          def cluster_key(sample)
            sample.cluster ? "c:#{sample.cluster}" : "s:#{sample.id}"
          end

          def utf16(text) = text.encode(Encoding::UTF_16BE).b

          private

          def unique!(samples, name)
            duplicate = samples.map(&:id).tally.find { |_, count| count > 1 }
            raise ArgumentError, "#{name} has the sample id #{duplicate.first.inspect} twice" if duplicate
          end

          def fits!(sample, reducer, scale)
            if scale == "binary" && !votes?(sample.trials)
              raise ArgumentError, "on a binary scale every trial is true or false (sample #{sample.id.inspect})"
            end
            return unless reducer.bootstrap? && reducer.k > sample.trials.size

            raise ArgumentError, "#{reducer.name} needs at least #{reducer.k} trials (sample #{sample.id.inspect})"
          end

          def votes?(trials) = trials.all? { |trial| [true, false].include?(trial) }
        end
      end
      private_constant :SampleList
    end
  end
end
