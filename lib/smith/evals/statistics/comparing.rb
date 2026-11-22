# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # compare and compare_many. Experimental until slice 1b freezes them.
      module Comparing
        LABEL_LENGTH = (1..128)
        CODE = /\A[a-z][a-z0-9_]{0,63}\z/

        # rubocop:disable Metrics/ParameterLists -- the interface's keywords are frozen (design 7.1)
        # One candidate against the baseline, paired by sample id (design 7.5).
        def compare(baseline:, candidate:, reducer:, scale: :binary, margin: 0.0, confidence: 0.95,
                    no_worse_margin: nil)
          comparer = Comparing.comparer(baseline, reducer, scale, margin)
          level = Inputs.confidence!(confidence)
          no_worse_margin = Inputs.no_worse_margin!(no_worse_margin)
          other = SampleList.check!(candidate, "candidate", reducer: comparer.reducer, scale: comparer.scale)
          comparer.comparison(comparer.pairing(other), other, level, no_worse_margin)
        end
        # rubocop:enable Metrics/ParameterLists

        # rubocop:disable Metrics/ParameterLists -- the interface's keywords are frozen (design 7.1)
        # Holm across every candidate named; each compared candidate's
        # interval at its Holm level. These per-candidate intervals agree
        # with Holm's decisions but are not simultaneous intervals.
        def compare_many(baseline:, candidates:, reducer:, scale: :binary, margin: 0.0, confidence: 0.95,
                         baseline_label: "baseline", no_worse_margin: nil)
          comparer = Comparing.comparer(baseline, reducer, scale, margin)
          level = Inputs.confidence!(confidence)
          no_worse_margin = Inputs.no_worse_margin!(no_worse_margin)
          label = Comparing.label!(baseline_label, "baseline_label")
          rows = Comparing.candidates!(candidates, comparer)
          SampleList.bootstrap_work!(comparer.base.size, RESAMPLES) if comparer.reducer.bootstrap?
          ComparisonSetBuilder.new(comparer, rows, label:, level:, no_worse_margin:).call
        end
        # rubocop:enable Metrics/ParameterLists

        class << self
          def comparer(baseline, reducer, scale, margin)
            kind = Inputs.reducer!(reducer)
            scale = Inputs.scale!(scale, kind)
            margin = Inputs.margin!(margin)
            Comparer.new(SampleList.check!(baseline, "baseline", reducer: kind, scale:), kind, scale, margin)
          end

          def label!(value, name)
            text = Inputs.text!(value, name)
            return text if LABEL_LENGTH.cover?(text.length)

            raise ArgumentError, "#{name} is at most #{LABEL_LENGTH.max} characters"
          end

          # [[label, counted samples or nil, reason code or nil], ...],
          # checked before any work.
          def candidates!(value, comparer)
            unless value.is_a?(Array) && (1..MAX_CANDIDATES).cover?(value.size)
              raise ArgumentError, "candidates are an Array of 1 to #{MAX_CANDIDATES} [label, samples, reason]"
            end

            rows = value.map { |row| candidate!(row, comparer) }
            return rows if rows.map(&:first).uniq.size == rows.size

            raise ArgumentError, "every candidate's label is its own"
          end

          private

          def candidate!(row, comparer)
            raise ArgumentError, "a candidate is [label, samples or nil, reason code or nil]" unless row in [_, _, _]

            label = label!(row[0], "a candidate's label")
            return [label, nil, row[2] && reason!(row[2])] if row[1].nil?
            raise ArgumentError, "a compared candidate has no reason code (#{label.inspect})" unless row[2].nil?

            [label, samples!(row[1], label, comparer), nil]
          end

          def samples!(samples, label, comparer)
            SampleList.check!(samples, "candidate #{label.inspect}", reducer: comparer.reducer, scale: comparer.scale)
          end

          def reason!(value)
            code = value.is_a?(Symbol) ? value.name : value
            return code if code.is_a?(String) && code.match?(CODE)

            raise ArgumentError, "a reason code is lowercase letters, digits and _, starting with a letter"
          end
        end
      end
      private_constant :Comparing
    end
  end
end
