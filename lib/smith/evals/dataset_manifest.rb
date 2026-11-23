# frozen_string_literal: true

require "json"
require_relative "actor"
require_relative "errors"
require_relative "identity"
require_relative "json_value"
require_relative "split_rule"

module Smith
  module Evals
    # Experimental; the format (smith.evals.dataset_manifest/1) is frozen
    # with slice 1a.2. A dataset's manifest (contracts'
    # dataset-manifest.schema.json): its version, its four part hashes, its
    # one split assignment, the counts a screen shows and every re-split
    # Smith's builds made (`resplits`, kept while the previous manifest is
    # there: a note for readers, not evidence). `warnings` is never written:
    # a cluster a hand-set split made straddle splits, and the samples a
    # rebuild moved to another split.
    class DatasetManifest
      FORMAT = "smith.evals.dataset_manifest"
      SAMPLES_FORMAT = "smith.evals.sample/1"
      SAMPLES_FILE = "samples.jsonl"
      FIELDS = %w[format format_version name version created_at created_by samples_file samples_format sample_count
                  hashes split_rule split_assignment split_counts hand_assigned clusters labels retention
                  previous_version resplits].freeze
      # The fields computed from the samples, which loading checks.
      DERIVED = %w[version split_assignment split_counts sample_count hand_assigned clusters labels retention].freeze
      PARTS = %w[inputs labels splits metadata].freeze

      attr_reader :warnings

      # A manifest for sample Hashes (each a line's JSON form) under a split
      # rule; DatasetInvalid names a sample that is not in its format.
      # `previous` is the manifest this one replaces, if any; a split rule
      # other than its own is refused unless `resplit: true`.
      def self.build(samples, name:, holdout:, calibration:, seed:, created_by: nil, previous: nil, resplit: false)
        rule = SplitRule.new(seed:, holdout:, calibration:)
        compose(Contents.from_lines(samples, rule), name:, created_by:, previous:, resplit:)
      end

      # The manifest for samples already checked (Contents). An unchanged
      # version keeps the previous manifest's previous_version; a changed
      # one names the previous version. A rule that differs from the
      # previous manifest's would move samples between splits (dev samples
      # already read into holdout), so it needs `resplit: true` and is
      # recorded in `resplits`.
      def self.compose(contents, name:, created_by: nil, previous: nil, resplit: false)
        raise ArgumentError, "a dataset name matches #{Identity::NAME.source}" unless Identity::NAME.match?(name.to_s)

        made = { "created_at" => now, "created_by" => actor(created_by) }
        data = { "format" => FORMAT, "format_version" => 1, "name" => name.to_s, "samples_file" => SAMPLES_FILE,
                 "samples_format" => SAMPLES_FORMAT, "previous_version" => prior(contents, previous),
                 "resplits" => resplits(contents.rule, previous, resplit, made) }
        new(data.merge(made, contents.fields), warnings: contents.warnings + moved(contents, previous))
      end

      # A manifest Hash read from a file or a host source, checked against
      # its format; DatasetInvalid names the first problem.
      def self.from_h(value, where: "manifest")
        problem = Format.problem(value)
        raise DatasetInvalid, "#{where}: #{problem}" if problem

        new(value)
      end

      # The manifest of a folder or a host source, in the given scope; a
      # host's Hash is read with String keys, as its samples are. O(N).
      def self.read(source, scope:)
        return from_h(source.manifest(scope:), where: FileDataset::MANIFEST) if source.is_a?(FileDataset)

        from_h(JSONValue.frozen(source.manifest(scope:)))
      end

      def self.now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")

      def self.actor(value)
        value.is_a?(Actor) ? value.to_h : Actor.from_h(value)&.to_h
      end

      def self.prior(contents, previous)
        return if previous.nil?

        previous.version == contents.version ? previous.previous_version : previous.version
      end

      # made: the build's created_at and created_by, the re-split's at and by.
      def self.resplits(rule, previous, resplit, made)
        return [] if previous.nil?
        return previous.resplits if previous.split_rule.to_h == rule.to_h

        unless resplit
          raise ArgumentError, "the split rule differs from the manifest's, so samples would move between splits; " \
                               "keep its seed and shares, or pass resplit: true to redraw the splits"
        end

        previous.resplits + [{ "at" => made["created_at"], "by" => made["created_by"],
                               "previous_version" => previous.version,
                               "previous_split_rule" => previous.split_rule.to_h }]
      end

      # One warning for each (from, to) pair of splits some samples left.
      def self.moved(contents, previous)
        return [] if previous.nil?

        moves(contents, previous).group_by { _1.first(2) }.map do |(from, to), list|
          { code: "samples_moved", from:, to:, ids: list.map(&:last) }.freeze
        end
      end

      # [from, to, id] for each sample whose split changed, in id order.
      def self.moves(contents, previous)
        before = previous.split_assignment.flat_map { |split, ids| ids.map { [_1, split] } }.to_h
        contents.entries.filter_map do |entry|
          from = before.fetch(entry[:id], entry[:split])
          [from, entry[:split], entry[:id]] unless from == entry[:split]
        end
      end
      private_class_method :now, :actor, :prior, :resplits, :moved, :moves

      def initialize(data, warnings: [])
        @data = JSONValue.frozen(FIELDS.to_h { [_1, data[_1]] })
        @warnings = warnings.map(&:freeze).freeze
        freeze
      end

      FIELDS.each { |field| define_method(field) { @data[field] } }

      def split_rule = SplitRule.from_h(@data["split_rule"])

      def to_h = @data

      # The file form: indented JSON and a line feed, as the examples are.
      # An empty Array or object is [] or {} whatever the json version (before
      # 2.8 it spread one over lines); no JSON string holds a raw newline.
      def file_text = "#{JSON.pretty_generate(@data).gsub(/\[\n\s*\]/, "[]").gsub(/\{\n\s*\}/, "{}")}\n"
    end
  end
end

require_relative "dataset_manifest/contents"
require_relative "dataset_manifest/format"
