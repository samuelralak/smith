# frozen_string_literal: true

require_relative "reflection"

module Smith
  module Tuning
    # Experimental. A tuning run's settings (slice 5a design, sections 1 and
    # 3), checked when built: ArgumentError names the setting. `to_h` is the
    # header's settings block, the method's fixed rules named with their
    # versions. A host object is held, never recorded: the reflection's
    # budget ledger caps its calls, and its limits are not settings.
    #
    #   Settings.new(objective: :exact_match,
    #                split: { train: { tags_any: ["train"] }, validation: { tags_any: ["val"] } },
    #                reflection: { model: "gpt-4.1-mini-2025-04-14", provider: :openai, temperature: 1.0,
    #                              max_output_tokens: 16_384, budget_ledger: ledger },
    #                stop: { max_metric_calls: 1_100, rounds_without_improvement: nil })
    #
    # components: the component ids tuned, in rotation order; nil for
    # every named prompt the subject sends, in its order. split: the
    # training and validation narrowings of the suite's selection
    # ({ids:} or {tags_any:}), and an override of the minimum sizes
    # ({actor:, reason:}); the carve of dev (5a-F) is not built, so a run
    # names its split. stop: at least one of max_metric_calls,
    # max_cost_nanos, rounds_without_improvement (5 by default; the plan's
    # rule, which the pilot turns off) and deadline (a Time), so every run
    # ends; max_candidates is always set. The deadline is an absolute time
    # and a setting, so in the tuning digest: a resume passes the header's,
    # never one worked out afresh from the clock.
    class Settings
      # The reflection model and what its call is sent with, checked when
      # built from the `reflection:` setting; `recorded` is the header's.
      ReflectionModel = Data.define(:model, :provider, :temperature, :max_output_tokens, :thinking,
                                    :budget_ledger) do
        def self.build(value)
          unless value.is_a?(Hash) && (value.keys - members).empty?
            raise ArgumentError, "reflection takes #{members.join(", ")}"
          end

          new(**members.to_h { [_1, checked(_1, value[_1])] })
        end

        # The budget ledger is the host's, held as given.
        def self.checked(member, value)
          case member
          when :model, :provider then name!(value, member)
          when :temperature then temperature!(value)
          when :max_output_tokens then tokens!(value)
          when :thinking then thinking!(value)
          else value
          end
        end

        def self.name!(value, what)
          text = value.to_s if value.is_a?(String) || value.is_a?(Symbol)
          return text.dup.freeze if text && !text.empty? && text.length <= 256

          raise ArgumentError, "reflection's #{what} is a name of 1 to 256 characters"
        end

        def self.temperature!(value)
          return value if value.nil? || (value.is_a?(Numeric) && value.real? && value.finite? && value >= 0)

          raise ArgumentError, "reflection's temperature is nil or a number of at least 0"
        end

        def self.tokens!(value)
          return value if value.nil? || (value.is_a?(Integer) && value.positive?)

          raise ArgumentError, "reflection's max_output_tokens is nil or an Integer of at least 1"
        end

        # As a step record writes what a call was sent with: nil (not sent),
        # or an effort (a name) and a budget (tokens), at least one.
        def self.thinking!(value)
          return if value.nil?

          thinking = { "effort" => value[:effort]&.to_s, "budget" => value[:budget] }.compact if thinking?(value)
          return thinking.freeze if thinking && !thinking.empty?

          raise ArgumentError, "reflection's thinking is nil or {effort:, budget:}, at least one"
        end

        def self.thinking?(value)
          return false unless value.is_a?(Hash) && (value.keys - %i[effort budget]).empty?

          effort, budget = value.values_at(:effort, :budget)
          (effort.nil? || effort?(effort)) && (budget.nil? || (budget.is_a?(Integer) && budget.positive?))
        end

        def self.effort?(effort) = (effort.is_a?(String) || effort.is_a?(Symbol)) && effort.length.between?(1, 64)
        private_class_method :checked, :name!, :temperature!, :tokens!, :thinking!, :thinking?, :effort?

        def recorded
          { "model" => model, "provider" => provider,
            "settings" => { "temperature" => temperature, "max_output_tokens" => max_output_tokens,
                            "thinking" => thinking },
            "prompt" => { "id" => Reflection::PROMPT.component_id, "version" => Reflection::PROMPT.version } }
        end
      end

      STOP = { max_metric_calls: nil, max_cost_nanos: nil, max_candidates: 1_000, rounds_without_improvement: 5,
               deadline: nil }.freeze
      # A JSON integer every reader keeps exactly.
      MAX_SEED = (2**53) - 1

      attr_reader :objective, :components, :split, :minibatch, :seed, :skip_perfect, :perfect_score, :reflection,
                  :stop

      def initialize(objective:, split:, reflection:, components: nil, minibatch: 3, seed: 0, skip_perfect: true,
                     perfect_score: 1.0, stop: {})
        @objective = Checks.objective!(objective)
        @components = Checks.components!(components)
        @split = Checks.split!(split)
        @minibatch = Checks.positive!(minibatch, "minibatch")
        @seed = Checks.seed!(seed)
        @skip_perfect = Checks.flag!(skip_perfect, "skip_perfect")
        @perfect_score = Checks.score!(perfect_score)
        @reflection = ReflectionModel.build(reflection)
        @stop = Checks.stop!(stop)
        freeze
      end

      def to_h
        { "minibatch" => minibatch, "seed" => seed, "skip_perfect" => skip_perfect, "perfect_score" => perfect_score,
          "failure_score" => 0, "selection" => "pareto/1", "rotation" => "round_robin/1",
          "accept" => "strict_mean/1", "merge" => false, "stop" => stop_h, "reflection" => reflection.recorded }
      end

      private

      def stop_h
        stop.transform_keys(&:to_s).merge("deadline" => stop[:deadline]&.then { Evals::Store::Clock.timestamp(_1) })
      end

      # Internal. Each setting's check, returning it as kept (frozen).
      module Checks
        BOUNDS = %i[max_metric_calls max_cost_nanos rounds_without_improvement deadline].freeze
        SCORER_NAME = /\A[a-z][a-z0-9_]{0,63}\z/
        NARROWINGS = %i[ids tags_any].freeze
        MAX_REASON_CHARACTERS = 1024

        module_function

        def objective!(value)
          name = value.to_s if value.is_a?(String) || value.is_a?(Symbol)
          return name.dup.freeze if name&.match?(SCORER_NAME)

          raise ArgumentError, "objective is the name of one of the suite's scorers"
        end

        def components!(value)
          return if value.nil?
          return value.map { _1.dup.freeze }.freeze if distinct?(value) && value.all? { ContentIdentity::ID.match?(_1) }

          raise ArgumentError, "components is nil or a list of distinct component ids"
        end

        def split!(value)
          if value.nil?
            raise ArgumentError, "split names the training and validation narrowings (the carve of dev is not built)"
          end
          unless value.is_a?(Hash) && (value.keys - %i[train validation override]).empty?
            raise ArgumentError, "split takes train:, validation: and override: only"
          end

          { train: narrowing!(value[:train], "train"), validation: narrowing!(value[:validation], "validation"),
            override: override!(value[:override]) }.freeze
        end

        def narrowing!(value, part)
          key, list = value.first if value.is_a?(Hash) && value.size == 1
          return { key => list.map { _1.dup.freeze }.freeze }.freeze if NARROWINGS.include?(key) && distinct?(list)

          raise ArgumentError, "split's #{part} is {ids: [...]} or {tags_any: [...]}, a list of distinct names"
        end

        def override!(value)
          return if value.nil?
          raise ArgumentError unless value.is_a?(Hash)

          actor = value[:actor].is_a?(Evals::Actor) ? value[:actor] : Evals::Actor.from_h(value[:actor])
          reason = value[:reason]
          return { actor:, reason: reason.dup.freeze }.freeze if actor && reason?(reason)

          raise ArgumentError
        rescue ArgumentError
          raise ArgumentError, "split's override names its actor and a reason of at most 1,024 characters"
        end

        def seed!(value)
          return value if value.is_a?(Integer) && value.between?(0, MAX_SEED)

          raise ArgumentError, "seed is an Integer from 0 to 2**53 - 1"
        end

        def score!(value)
          return Float(value) if value.is_a?(Numeric) && value.real? && value.between?(0, 1)

          raise ArgumentError, "perfect_score is a number from 0 to 1"
        end

        def flag!(value, name)
          return value if [true, false].include?(value)

          raise ArgumentError, "#{name} is true or false"
        end

        def positive!(value, name, nullable: false)
          return value if (nullable && value.nil?) || (value.is_a?(Integer) && value.positive?)

          raise ArgumentError, "#{name} is #{"nil or " if nullable}an Integer of at least 1"
        end

        def stop!(value)
          unless value.is_a?(Hash) && (value.keys - STOP.keys).empty?
            raise ArgumentError, "stop takes #{STOP.keys.join(", ")}"
          end

          checked = STOP.merge(value).to_h { |key, given| [key, limit!(key, given)] }
          return checked.freeze if BOUNDS.any? { checked[_1] }

          raise ArgumentError, "stop sets at least one of #{BOUNDS.join(", ")}, so the run ends"
        end

        def limit!(key, value)
          case key
          when :max_cost_nanos then cost!(value)
          when :deadline then deadline!(value)
          else positive!(value, "stop's #{key}", nullable: key != :max_candidates)
          end
        end

        def cost!(value)
          return value if value.nil? || (value.is_a?(Integer) && value >= 0)

          raise ArgumentError, "stop's max_cost_nanos is nil or an Integer of at least 0"
        end

        def deadline!(value)
          return value&.getutc&.freeze if value.nil? || value.is_a?(Time)

          raise ArgumentError, "stop's deadline is nil or a Time"
        end

        def distinct?(list)
          list.is_a?(Array) && !list.empty? && list.uniq.size == list.size &&
            list.all? { _1.is_a?(String) && !_1.empty? }
        end

        def reason?(reason) = reason.is_a?(String) && !reason.strip.empty? && reason.length <= MAX_REASON_CHARACTERS
      end
      private_constant :Checks
    end
  end
end
