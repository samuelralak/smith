# frozen_string_literal: true

require_relative "configuration"
require_relative "dataset_manifest"
require_relative "file_dataset"
require_relative "sample"

module Smith
  module Evals
    # Experimental. A dataset, loaded and verified (slice-1a design, 4.2 and
    # 8.2): every sample checked, every hash and count recomputed and
    # compared with its manifest, its samples sorted by id in UTF-16 code
    # units. A source is a folder (FileDataset) or a host object answering
    # `manifest(scope:)` (the manifest Hash) and `each_sample(scope:)`
    # (yielding sample Hashes). O(S + n log n) time for S sample bytes.
    #
    #   Smith::Evals::Dataset.build_manifest("evals/support_tickets", name: "support-tickets",
    #     holdout: 0.25, calibration: 0.05, seed: "support-tickets-2026-11")
    #   dataset = Smith::Evals::Dataset.load("evals/support_tickets")
    #   dataset.split(:dev) # => Smith::Evals::Sample list
    class Dataset
      attr_reader :manifest, :source, :samples, :warnings

      # Writes the folder's manifest.json for its samples.jsonl, keeping a
      # hand-set split and assigning the rest by the rule; returns the
      # DatasetManifest, whose `warnings` (never written) name a cluster a
      # hand-set split made straddle splits and the samples the rebuild
      # moved. A rule other than the manifest's is refused (ArgumentError)
      # unless `resplit: true`, which redraws the splits and records it.
      def self.build_manifest(path, name:, holdout:, calibration:, seed:, created_by: nil, resplit: false)
        folder = FileDataset.new(path, samples_file: DatasetManifest::SAMPLES_FILE)
        previous = folder.manifest? ? DatasetManifest.read(folder, scope: nil) : nil
        rule = SplitRule.new(seed:, holdout:, calibration:)
        contents = DatasetManifest::Contents.new(folder.each_placed_sample, rule)
        DatasetManifest.compose(contents, name:, created_by:, previous:, resplit:)
                       .tap { folder.write_manifest(_1.file_text) }
      end

      # The dataset at a folder or from a host source. DatasetInvalid when
      # something is not in its format; DatasetChanged when the samples do
      # not match the manifest, or the version is not the one pinned.
      def self.load(source, scope: nil, version: nil)
        scope = Smith::Scope.build(scope || Evals.config.default_scope)
        source = FileDataset.new(source) if source.is_a?(String) || source.respond_to?(:to_path)
        manifest = DatasetManifest.read(source, scope:)
        contents = contents(source, scope, manifest.split_rule)
        Verification.new(manifest, contents, pinned: version).check!
        new(manifest:, contents:, source:)
      end

      def self.contents(source, scope, rule)
        return DatasetManifest::Contents.new(source.each_placed_sample, rule) if source.is_a?(FileDataset)

        DatasetManifest::Contents.from_lines(source.enum_for(:each_sample, scope:), rule)
      end
      private_class_method :contents

      # warnings: clusters a hand-set split made straddle splits, as
      # build_manifest names them.
      def initialize(manifest:, contents:, source:)
        @manifest = manifest
        @source = source
        @samples = contents.entries.map { Sample.new(_1[:line], split: _1[:split]) }.freeze
        @by_id = @samples.to_h { [_1.id, _1] }.freeze
        @splits = @samples.group_by(&:split).transform_values(&:freeze).freeze
        @warnings = contents.warnings
        freeze
      end

      def name = manifest.name
      def version = manifest.version
      def hashes = manifest.hashes

      # The samples assigned to a split (:dev, :holdout or :calibration),
      # sorted by id.
      def split(name)
        key = name.to_sym
        raise ArgumentError, "a split is dev, holdout or calibration" unless %i[dev holdout calibration].include?(key)

        @splits.fetch(key, [].freeze)
      end

      def sample(id) = @by_id[id]

      # Compares a manifest with what its samples give it.
      class Verification
        def initialize(manifest, contents, pinned:)
          @manifest = manifest
          @contents = contents
          @pinned = pinned
        end

        def check!
          changed = changed_fields
          unless changed.empty?
            raise DatasetChanged.new("the samples do not match the manifest: #{changed.join(", ")}", parts: changed)
          end
          return if @pinned.nil? || @pinned == @manifest.version

          raise DatasetChanged.new("the dataset version is not the pinned #{@pinned}", parts: ["version"])
        end

        private

        # The part hashes, then the derived fields, that differ. Within a
        # derived object only the keys this version derives are compared:
        # readers ignore fields they do not know.
        def changed_fields
          derived = @contents.derived
          DatasetManifest::PARTS.reject { @manifest.hashes[_1] == @contents.hashes[_1] } +
            DatasetManifest::DERIVED.reject { same?(@manifest.public_send(_1), derived[_1]) }
        end

        def same?(stated, derived)
          return stated == derived unless derived.is_a?(Hash) && stated.is_a?(Hash)

          stated.slice(*derived.keys) == derived
        end
      end
      private_constant :Verification
    end
  end
end
