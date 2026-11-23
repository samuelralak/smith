# frozen_string_literal: true

module Smith
  module Evals
    module SuiteManifest
      # Internal. A suite's scorer declarations, each resolved to a scorer
      # and checked: its name (unique), its version, scale and failure rule,
      # and its reducers (each fitting its scale and its trials). Problems
      # go to the list it is given, by index ("/scorers/2/reduce: ...").
      class ScorerCheck
        include Facts

        NAME = /\A[a-z][a-z0-9_]{0,63}\z/
        SCALES = %i[binary continuous].freeze
        FAILURE_RULES = %i[fail score].freeze
        VERSION = "is required: an Integer of at least 1 you bump when the scorer's meaning changes"
        INTEGER = "is an Integer from 1 to 2**53 - 1"

        attr_reader :entries

        def initialize(declared, default_reduce:, per_sample:, problems:)
          @default_reduce = default_reduce
          @per_sample = per_sample
          @problems = problems
          @problems << "/scorers: a suite needs at least one scorer" if declared.empty?
          @problems << "/scorers: holds at most #{MAX_SCORERS} scorers" if declared.size > MAX_SCORERS
          @names = []
          @declared = declared.filter_map { scorer_name_of(_1) }
          @entries = declared.each_with_index.filter_map { |entry, index| resolve(entry, "/scorers/#{index}") }.freeze
        end

        def named(name) = entries.find { _1.name == name.to_s }

        # Whether a scorer was declared under the name, refused or not: a
        # refused one already has its problem line.
        def declared?(name) = @declared.include?(name.to_s)

        def manifest
          entries.map do |entry|
            { "name" => entry.name, "kind" => "code", "version" => entry.version, "scale" => entry.scale.to_s,
              "reduce" => entry.reduce, "also" => entry.also, "on_subject_failure" => entry.on_subject_failure.to_s }
          end
        end

        private

        def resolve(entry, path)
          scorer = scorer_for(entry, path)
          return if scorer.nil?

          rule = (entry[:on_subject_failure] || scorer.on_subject_failure)&.to_sym
          settled?(path, scorer, rule) && entry_for(entry, path, scorer, rule)
        end

        def entry_for(entry, path, scorer, rule)
          reduce = headline(entry[:reduce], path, scorer.scale)
          also = also(entry[:also], path, scorer.scale, reduce)
          return if reduce.nil? || also.nil?

          ScorerEntry.new(scorer:, name: scorer.name, version: scorer.version, scale: scorer.scale, reduce:, also:,
                          on_subject_failure: rule)
        end

        # The declared reducer, or the suite's (mean for a continuous scorer).
        def headline(declared, path, scale)
          return fitted(declared, "#{path}/reduce", scale) if declared

          scale == :continuous ? "mean" : @default_reduce
        end

        def scorer_for(entry, path)
          target = entry[:target]
          return block_scorer(entry, path) if entry[:block]
          return class_scorer(entry, path) if target.is_a?(Class) && target < Scorer
          return (target if own_settings?(entry, path)) if target.is_a?(Scorer)

          @problems << "#{path}: is a name and a block, a Smith::Evals::Scorer class or a scorer"
          nil
        end

        # A Scorer, class or instance, declares its version and scale; the
        # suite gives only its reducers and failure rule.
        def own_settings?(entry, path)
          given = entry[:version] || entry[:scale]
          @problems << "#{path}: a Scorer declares its own version and scale" if given
          !given
        end

        def block_scorer(entry, path)
          name = entry[:target]
          return refused("#{path}/name", "is a Symbol or String") unless name.is_a?(Symbol) || name.is_a?(String)

          Scorer::Block.new(name: entry[:target], version: entry[:version], scale: entry[:scale] || :binary,
                            on_subject_failure: entry[:on_subject_failure] || :fail, &entry[:block])
        end

        def class_scorer(entry, path)
          own_settings?(entry, path)
          return entry[:target].new unless entry[:target].instance_method(:score).owner == Scorer

          @problems << "#{path}: must define score(sample, trial)"
          nil
        end

        # Whether the scorer's name, version, scale and failure rule hold;
        # each that does not is a problem.
        def settled?(path, scorer, rule)
          before = @problems.size
          name_once(path, scorer.name)
          @problems << "#{path}/version: #{scorer.version.nil? ? VERSION : INTEGER}" unless integer?(scorer.version, 1)
          @problems << "#{path}/scale: is binary or continuous" unless SCALES.include?(scorer.scale)
          @problems << "#{path}/on_subject_failure: is fail or score" unless FAILURE_RULES.include?(rule)
          @problems.size == before
        end

        def name_once(path, name)
          @problems << "#{path}/name: matches ^[a-z][a-z0-9_]{0,63}$" unless matches?(name, NAME)
          @problems << "#{path}/name: #{name} is used by another scorer" if @names.include?(name)
          @names << name
        end

        # The extra reducers' names, or nil when one is refused.
        def also(declared, path, scale, reduce)
          names = Array(declared).each_with_index.map { |item, index| fitted(item, "#{path}/also/#{index}", scale) }
          @problems << "#{path}/also: repeats the headline reducer #{reduce}" if reduce && names.include?(reduce)
          @problems << "#{path}/also: names a reducer twice" unless names.uniq.size == names.size
          names.freeze unless names.include?(nil)
        end

        # The reducer's name, if it fits the scale and the trials.
        def fitted(value, path, scale)
          name = Reducers.name_of(value)
          return refused(path, "#{name} does not fit a #{scale} scorer") unless Reducers.fits?(name, scale)

          k = Reducers.k(name)
          return name if k.nil? || !@per_sample.is_a?(Integer) || k <= @per_sample

          refused(path, "#{name} needs at least #{k} trials per sample, not #{@per_sample}")
        rescue ArgumentError
          refused(path, "is majority, any, all, mean, pass_at: k or pass_all: k")
        end

        def refused(path, text)
          @problems << "#{path}: #{text}"
          nil
        end
      end
      private_constant :ScorerCheck
    end
  end
end
