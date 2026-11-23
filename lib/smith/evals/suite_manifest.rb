# frozen_string_literal: true

require_relative "dataset_manifest"
require_relative "errors"
require_relative "file_dataset"
require_relative "identity"
require_relative "json_value"
require_relative "reducers"
require_relative "scorer"
require_relative "subject"

module Smith
  module Evals
    # Experimental; the format freezes with slice 1b (labels and judges with
    # slice 2). A suite as data (contracts' suite-manifest.schema.json,
    # slice-1a design 8.5): what a code suite declares, checked, every
    # default written out, with its version. The version leaves out the
    # budget and dataset.source; the measure digest (Identity) is what
    # comparisons read. O(N) in what the suite declares, plus reading the
    # dataset manifest's name.
    module SuiteManifest
      FORMAT = "smith.evals.suite_manifest"
      SPLITS = %w[dev holdout calibration].freeze
      MAX_SCORERS = 64
      MAX_GATES = 32

      # A scorer of a suite, resolved: its name, version, scale, reducers
      # and failure rule.
      ScorerEntry = Data.define(:scorer, :name, :version, :scale, :reduce, :also, :on_subject_failure)

      class << self
        # The manifest Hash (frozen, String keys, with "version").
        # SuiteInvalid lists every problem; a holdout or calibration suite
        # is refused with SplitNotAllowed until slice 2 counts its uses.
        def build(suite, scope:)
          checked = check!(suite)
          split = suite.split.to_s
          unless split == "dev"
            raise SplitNotAllowed, "suite #{suite.suite_name} runs on the #{split} split, which slice 1a refuses"
          end

          data = write(suite, checked, dataset_name(suite, scope))
          JSONValue.frozen(data.merge("version" => Identity.suite_version(data)))
        end

        def scorers(suite) = check!(suite).scorers.entries

        # The selected samples of a loaded dataset, sorted by id, as a
        # manifest's selection names them.
        def select(dataset, manifest)
          unless dataset.name == manifest.dig("dataset", "name")
            raise DatasetChanged.new("the dataset is now named #{dataset.name}", parts: ["name"])
          end

          split, narrow = manifest["selection"].values_at("split", "narrow")
          chosen = narrowed(dataset.split(split), narrow, "#{split} split", manifest["name"])
          return chosen unless chosen.empty?

          raise SuiteInvalid.new(["/selection: selects no sample of the #{split} split"], suite: manifest["name"])
        end

        # A reducer's record name, or nil for one Smith does not know.
        def reducer_name(value)
          Reducers.name_of(value)
        rescue ArgumentError
          nil
        end

        private

        def check!(suite)
          checked = Check.new(suite)
          return checked if checked.problems.empty?

          name = suite.suite_name
          raise SuiteInvalid.new(checked.problems, suite: name.is_a?(String) && JSONValue.utf8?(name) ? name : nil)
        end

        # The manifest, in the published examples' field order.
        def write(suite, checked, dataset_name)
          settings = suite.settings
          { "format" => FORMAT, "format_version" => 1, "name" => suite.suite_name,
            "dataset" => { "name" => dataset_name, "source" => source_text(suite),
                           "pinned_version" => settings[:pinned_version] },
            "selection" => { "split" => settings[:split].to_s, "narrow" => narrow(settings[:narrow]) },
            "subject" => settings[:subject].to_manifest }.merge(measured(settings, checked), slots(settings, checked))
        end

        def measured(settings, checked)
          { "trials" => { "per_sample" => settings[:trials], "error_retries" => settings[:error_retries],
                          "infrastructure_errors" => Identity.utf16_sort(settings[:infrastructure_errors].map(&:name)),
                          "reduce" => checked.reduce },
            "scorers" => checked.scorers.manifest, "statistics" => statistics(settings[:statistics]),
            "recording" => { "content" => settings[:recording][:content] } }
        end

        def slots(settings, checked)
          { "gates" => checked.gates.manifest, "budget" => settings[:budget]&.transform_keys(&:to_s),
            "labels" => { "accept" => settings[:labels][:accept].to_s }, "judges" => [] }
        end

        # A narrowing as sorted names: order never changes what it selects.
        def narrow(narrow) = narrow&.to_h { |key, list| [key.to_s, Identity.utf16_sort(list.map(&:to_s))] }

        def statistics(settings)
          { "level" => Float(settings[:level]), "bootstrap_resamples" => settings[:bootstrap_resamples],
            "small_sample_threshold" => settings[:small_sample_threshold] }
        end

        def source_text(suite)
          source = suite.dataset_source
          source.is_a?(String) ? source : nil
        end

        def dataset_name(suite, scope)
          source = suite.dataset_source
          source = FileDataset.new(source) if source.is_a?(String)
          DatasetManifest.read(source, scope:).name
        end

        # O(n + k) for n samples and k names.
        def narrowed(samples, narrow, split, suite)
          return samples if narrow.nil?
          return tagged(samples, narrow["tags_any"].to_set) if narrow.key?("tags_any")

          ids = narrow["ids"]
          missing = missing(samples, ids, split)
          raise SuiteInvalid.new(missing, suite:) unless missing.empty?

          wanted = ids.to_set
          samples.select { wanted.include?(_1.id) }
        end

        def missing(samples, ids, split)
          held = samples.to_set(&:id)
          ids.each_with_index.filter_map do |id, index|
            "/selection/narrow/ids/#{index}: #{id} is not in the #{split}" unless held.include?(id)
          end
        end

        def tagged(samples, tags) = samples.select { |sample| sample.tags.any? { tags.include?(_1) } }
      end
    end
  end
end

require_relative "suite_manifest/check"
require_relative "suite_manifest/scorer_check"
require_relative "suite_manifest/gate_check"
