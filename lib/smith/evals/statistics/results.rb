# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # Deep-freezes what a result holds, so a result never changes after it
      # is made.
      module Frozen
        def self.call(value)
          case value
          when Hash then value.to_h { |key, member| [call(key), call(member)] }.freeze
          when Array then value.map { |member| call(member) }.freeze
          when String then value.frozen? ? value : value.dup.freeze
          else value
          end
        end
      end
      private_constant :Frozen

      # A result's members as its smith.evals.stats/1 form: String keys in
      # member order, `method_name` written as "method", nested results as
      # their own form.
      module Form
        class << self
          def call(type, members)
            { "schema" => SCHEMA, "type" => type, **plain(members) }
          end

          def plain(members)
            members.to_h { |name, value| [name == :method_name ? "method" : name.to_s, json(value)] }
          end

          private

          def json(value)
            case value
            when Data then value.to_h
            when Hash then value.transform_values { |member| json(member) }
            when Array then value.map { |member| json(member) }
            else value
            end
          end
        end
      end
      private_constant :Form

      # One number with its interval: a pass rate, a mean, or a rate from
      # counts. `to_h` is its smith.evals.stats/1 form (type "estimate").
      # Frozen with slice 1a.1. The design names its display reader (7.1).
      Estimate = Data.define(:measure, :reducer, :method_name, :method_revision, :confidence, :basis, :n, :successes,
                             :clusters, :design_effect, :n_effective, :point, :lower, :upper, :approximate,
                             :warnings, :display, :inputs_digest, :seed) # rubocop:disable Lint/DataDefineOverride
      class Estimate
        def initialize(**fields) = super(**Frozen.call(fields))

        def to_h = Form.call("estimate", super)
      end

      # One candidate against one baseline, paired by sample id; the
      # difference is candidate minus baseline. `to_h` is its
      # smith.evals.stats/1 form (type "comparison"). Experimental until
      # slice 1b freezes it. The design names its display reader (7.1).
      Comparison = Data.define(:measure, :reducer, :method_name, :method_revision, :confidence, :margin, :pairs,
                               :only_in_baseline, :only_in_candidate, :baseline, :candidate, :changed, :difference,
                               :p_value, :test, :verdict, :verdict_rule, :no_worse, :approximate, :warnings,
                               :display, :inputs_digest) # rubocop:disable Lint/DataDefineOverride
      class Comparison
        def initialize(**fields) = super(**Frozen.call(fields))

        def to_h = Form.call("comparison", super)
      end

      # Several candidates against one baseline, Holm across every candidate
      # named, each compared candidate's interval at its Holm level. These
      # intervals agree with Holm's decisions but are not simultaneous
      # intervals. `to_h` is its smith.evals.stats/1 form (type
      # "comparison_set"). Experimental until slice 1b freezes it.
      ComparisonSet = Data.define(:measure, :reducer, :method_name, :method_revision, :confidence, :margin,
                                  :adjustment, :no_worse_margin, :no_worse_adjustment, :baseline, :candidates,
                                  :warnings, :inputs_digest)
      class ComparisonSet
        # One candidate's row: compared, or not compared with its reason code.
        Candidate = Data.define(:label, :status, :reason_code, :p_value, :adjusted_p, :level, :comparison, :verdict,
                                :no_worse)
        class Candidate
          def initialize(**fields) = super(**Frozen.call(fields))

          def to_h = Form.plain(super)
        end

        def initialize(**fields) = super(**Frozen.call(fields))

        def to_h = Form.call("comparison_set", super)
      end

      # rubocop:disable Lint/DataDefineOverride -- the design names this reader display (7.1)
      # The smallest change n samples can detect, either way, as low, typical
      # and high over stated correlations. `to_h` is its smith.evals.stats/1
      # form (type "detectable"). Frozen with slice 1a.1.
      Detectable = Data.define(:method_name, :method_revision, :n, :baseline, :paired, :power, :confidence,
                               :direction, :smallest_difference, :assumptions, :display)
      # rubocop:enable Lint/DataDefineOverride
      class Detectable
        def initialize(**fields) = super(**Frozen.call(fields))

        def to_h = Form.call("detectable", super)
      end

      # rubocop:disable Lint/DataDefineOverride -- the design names this reader display (7.1)
      # How many samples a difference needs, as low, typical and high over
      # stated correlations. `to_h` is its smith.evals.stats/1 form (type
      # "required_samples"). Frozen with slice 1a.1.
      RequiredSamples = Data.define(:method_name, :method_revision, :baseline, :difference, :paired, :power,
                                    :confidence, :samples, :assumptions, :display)
      # rubocop:enable Lint/DataDefineOverride
      class RequiredSamples
        def initialize(**fields) = super(**Frozen.call(fields))

        def to_h = Form.call("required_samples", super)
      end

      # How often a judge catches real failures and passes good answers,
      # against labels, and whether each rate meets the declared bar. `to_h`
      # is its smith.evals.stats/1 form (type "judge_check"). Frozen with
      # slice 1a.1.
      JudgeCheck = Data.define(:catches_failures, :passes_good, :bar, :meets_bar, :gates_on)
      class JudgeCheck
        def initialize(**fields) = super(**Frozen.call(fields))

        def to_h = Form.call("judge_check", super)
      end
    end
  end
end
