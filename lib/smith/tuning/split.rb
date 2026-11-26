# frozen_string_literal: true

module Smith
  module Tuning
    # A split the rules refuse: the parts share a sample, one selects none or
    # names an id the suite does not select, or one is under its minimum
    # with no override. The message names ids and counts, never content.
    class SplitRefused < Evals::Error; end

    # Experimental. A tuning run's training and validation ids (slice 5a
    # design, section 1, row 0; plan 5.3, step 1), given as two narrowings of
    # the suite's selection, each in the selection's order; the carve of dev
    # is 5a-F. Every selected sample is a dev sample (plan 4.4: the tuner's
    # sets come out of dev). The parts never share a sample, since a
    # validation sample must never reach a reflection. Under 10 training or 30
    # validation samples is refused unless an override ({actor:, reason:})
    # allows it, and the header records the override with its time. O(n) in
    # the selection.
    class Split
      MINIMUMS = { train: 10, validation: 30 }.freeze

      attr_reader :train_ids, :validation_ids, :override

      # samples: the suite's selection (Smith::Evals::Sample), sorted by id;
      # train and validation: {ids:} or {tags_any:}; at: the run's start.
      def self.given(samples, train:, validation:, override:, at:)
        dev!(samples)
        new(narrowed(samples, train, "train"), narrowed(samples, validation, "validation"), override:, at:)
      end

      def self.dev!(samples)
        others = samples.reject { _1.split == :dev }.group_by(&:split)
        return if others.empty?

        named = others.map { |split, held| "#{held.size} sample#{held.size == 1 ? " is" : "s are"} in the #{split}" }
        raise SplitRefused, "#{named.map { "#{_1} split" }.join(", ")}; a tuning run takes dev samples only"
      end
      private_class_method :dev!

      def self.narrowed(samples, narrowing, part)
        key, names = narrowing.first
        wanted = names.to_set
        chosen = samples.filter_map { _1.id if (key == :ids ? [_1.id] : _1.tags).any? { |name| wanted.include?(name) } }
        missing = names - chosen if key == :ids
        raise SplitRefused, "#{part} names #{missing.first}, which the suite does not select" if missing&.any?

        chosen
      end
      private_class_method :narrowed

      def initialize(train_ids, validation_ids, override:, at:)
        @train_ids = train_ids.freeze
        @validation_ids = validation_ids.freeze
        @override = override && { "actor" => override[:actor].to_h, "reason" => override[:reason],
                                  "at" => Evals::Store::Clock.timestamp(at) }.freeze
        check!
        freeze
      end

      # The header's split.
      def to_h
        { "rule" => "given", "train" => part(train_ids), "validation" => part(validation_ids), "ratio" => nil,
          "override" => override }
      end

      private

      def check!
        sized!(:train, train_ids)
        sized!(:validation, validation_ids)
        shared = (train_ids & validation_ids).size
        raise SplitRefused, "#{shared} samples are in both train and validation" if shared.positive?
      end

      def sized!(name, ids)
        raise SplitRefused, "#{name} selects no sample" if ids.empty?
        return if override || ids.size >= MINIMUMS[name]

        raise SplitRefused, "#{name} has #{ids.size} sample#{"s" unless ids.size == 1}; a run needs at least " \
                            "#{MINIMUMS[name]} unless an override allows fewer"
      end

      def part(ids) = { "count" => ids.size, "ids_digest" => Evals::Identity.sample_ids_digest(ids) }
    end
  end
end
