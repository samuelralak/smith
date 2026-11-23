# frozen_string_literal: true

require "digest"
require_relative "../canonical_json"

module Smith
  module Evals
    # Experimental; the rule is frozen with slice 1a.2. A dataset's one
    # split assignment (slice-1a design, 8.3): a sample's bucket is the
    # first 8 bytes of SHA-256 over "smith.evals.split/1\n" and the
    # canonical JSON of {"seed", "cluster"} (or {"seed", "id"} without a
    # cluster), read as an unsigned big-endian integer; it is holdout below
    # floor(holdout * 2**64), calibration below floor((holdout +
    # calibration) * 2**64), else dev. The thresholds are exact, from each
    # share's decimal spelling, so every language agrees; a sample's split
    # depends only on its own key, so adding samples never moves one and a
    # cluster stays together. O(1) per sample.
    class SplitRule
      FRAME = "smith.evals.split/1\n"
      SCALE = 2**64
      MAX_SEED_CHARACTERS = 256

      attr_reader :seed, :holdout, :calibration, :thresholds

      def self.from_h(value)
        raise ArgumentError, "a split rule is a Hash" unless value.is_a?(Hash)
        raise ArgumentError, "a split rule's method is hash_threshold" unless value["method"] == "hash_threshold"
        raise ArgumentError, "a split rule's key is cluster_or_id" unless value["key"] == "cluster_or_id"

        shares = value["shares"]
        raise ArgumentError, "a split rule's shares are a Hash" unless shares.is_a?(Hash)

        new(seed: value["seed"], holdout: shares["holdout"], calibration: shares["calibration"])
      end

      def initialize(seed:, holdout:, calibration:)
        unless utf8?(seed) && seed.length.between?(1, MAX_SEED_CHARACTERS)
          raise ArgumentError, "a split rule's seed is a String of 1 to #{MAX_SEED_CHARACTERS} characters of UTF-8"
        end

        @seed = seed.dup.force_encoding(Encoding::UTF_8).freeze
        @holdout = share!(holdout, "holdout")
        @calibration = share!(calibration, "calibration")
        @thresholds = exact_thresholds.freeze
        freeze
      end

      def bucket(id:, cluster:)
        key = cluster.nil? ? { "seed" => seed, "id" => id } : { "seed" => seed, "cluster" => cluster }
        Digest::SHA256.digest(FRAME + CanonicalJSON.generate(key)).byteslice(0, 8).unpack1("Q>")
      end

      # "holdout", "calibration" or "dev".
      def assign(id:, cluster:)
        value = bucket(id:, cluster:)
        return "holdout" if value < thresholds[0]
        return "calibration" if value < thresholds[1]

        "dev"
      end

      def to_h
        { "method" => "hash_threshold", "seed" => seed, "key" => "cluster_or_id",
          "shares" => { "holdout" => holdout, "calibration" => calibration } }
      end

      private

      # A share as the JSON number the manifest keeps: a finite real in 0..1,
      # a Float (so 1/4r is 0.25), never -0.0.
      def share!(value, name)
        unless value.is_a?(Numeric) && value.real? && value.to_f.finite? && value.between?(0, 1)
          raise ArgumentError, "the #{name} share is a number from 0 to 1"
        end

        Float(value) + 0.0
      end

      # UTF-8, or ASCII in any encoding, as canonical JSON takes it.
      def utf8?(text)
        text.is_a?(String) && ((text.encoding == Encoding::UTF_8 && text.valid_encoding?) || text.ascii_only?)
      end

      # floor(share * 2**64) from the share's shortest decimal spelling (the
      # one the manifest's JSON holds), as a Rational: Float arithmetic
      # would round, and another language would disagree.
      def exact_thresholds
        held = Rational(holdout.to_s)
        both = held + Rational(calibration.to_s)
        raise ArgumentError, "the holdout and calibration shares add up to at most 1" if both > 1

        [(held * SCALE).floor, (both * SCALE).floor]
      end
    end
  end
end
