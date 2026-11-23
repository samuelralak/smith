# frozen_string_literal: true

require_relative "score"

module Smith
  module Evals
    # Experimental. A code scorer (slice-1a design, 4.3), reusable across
    # suites. Its author declares its name, a version to bump when its
    # meaning changes, its scale (:binary by default, or :continuous) and,
    # optionally, what a failed subject means for it (:fail, the default,
    # counts it as a fail without running the scorer; :score runs it with
    # `trial.failure` set). A suite names the reducers.
    #
    #   class CategoryScorer < Smith::Evals::Scorer
    #     scorer_name :category
    #     version 1
    #     def score(sample, trial) = Smith::Evals::Score.match(trial.state.dig(:triage, :category),
    #                                                          sample.expected[:category])
    #   end
    #
    # A scorer runs outside trial isolation, on what the trial line keeps
    # (the sample, `trial.state`, `trial.output`, `trial.steps`), so a
    # stored record can be scored again without running anything.
    class Scorer
      SETTINGS = { scorer_name: nil, version: nil, scale: :binary, on_subject_failure: :fail }.freeze

      class << self
        SETTINGS.each_key do |setting|
          define_method(setting) do |value = (unset = true)|
            return own_setting(setting) if unset

            (@settings ||= {})[setting] = value
          end
        end

        private

        def own_setting(setting)
          return @settings[setting] if @settings&.key?(setting)
          return superclass.public_send(setting) if superclass.respond_to?(setting)

          SETTINGS[setting]
        end
      end

      def name = self.class.scorer_name&.to_s
      def version = self.class.version
      def scale = self.class.scale
      def on_subject_failure = self.class.on_subject_failure

      # Returns the Score for one trial.
      def score(_sample, _trial)
        raise NotImplementedError, "#{self.class} defines score(sample, trial)"
      end

      # The Score for one trial, whatever the scorer does: one on the other
      # scale, or anything but a Score, is unscored score_invalid; one that
      # raises is unscored scorer_raised.
      def evaluate(sample, trial)
        result = score(sample, trial)
        return Score.invalid("scorer #{name} returned something other than a Score") unless result.is_a?(Score)
        return result if result.status == :unscored || result.scale == scale

        Score.invalid("scorer #{name} is #{scale} and returned a #{result.scale} score")
      rescue StandardError => e
        Score.raised(name, e)
      end

      # A scorer from a block, as `scorer :name, version: 1 do ... end` in a
      # suite makes.
      class Block < Scorer
        attr_reader :name, :version, :scale, :on_subject_failure

        def initialize(name:, version:, scale: :binary, on_subject_failure: :fail, &block)
          super()
          @name = name&.to_s
          @version = version
          @scale = scale
          @on_subject_failure = on_subject_failure
          @block = block
        end

        def score(sample, trial) = @block.call(sample, trial)
      end
    end
  end
end
