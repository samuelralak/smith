# frozen_string_literal: true

require_relative "configuration"
require_relative "dataset"
require_relative "identity"
require_relative "scorer"
require_relative "subject"
require_relative "suite_manifest"

module Smith
  module Evals
    # Experimental. A suite (slice-1a design, 4.5): a dataset, a split and
    # its narrowing, a subject, trials and reducers, scorers, statistics,
    # recording, and the slots later slices act on (gates, budget, labels).
    # Declarations are data; `manifest` checks them all at once (SuiteInvalid
    # names every problem) and writes them out, every default filled.
    #
    #   class TicketTriageSuite < Smith::Evals::Suite
    #     suite_name "support.ticket_triage"
    #     dataset "support_tickets"
    #     subject workflow: TicketTriage, input: ->(sample) { { ticket: sample.input[:text] } }, keep: %i[triage]
    #     trials 3, reduce: :majority
    #     scorer(:category, version: 1) { |sample, trial| Smith::Evals::Score.match(...) }
    #     gate :category_floor, scorer: :category, at_least: 0.8
    #   end
    #   TicketTriageSuite.version        # => "sha256:..."
    #   TicketTriageSuite.measure_digest # => "sha256:..." (reads the dataset)
    class Suite
      # What a suite runs on: its manifest, its verified dataset, the
      # selected samples (sorted by id) and their digests.
      Selection = Data.define(:manifest, :dataset, :samples, :sample_ids_digest, :measure_digest)

      DEFAULTS = { name: nil, dataset: nil, pinned_version: nil, split: :dev, narrow: nil, subject: nil, trials: 3,
                   reduce: :majority, error_retries: 2, concurrency: 1, infrastructure_errors: [],
                   statistics: { level: 0.95, bootstrap_resamples: 2_000, small_sample_threshold: 30 },
                   driver: nil, recording: { content: true }, scorers: [], gates: [], budget: nil,
                   labels: { accept: :any } }.freeze
      NONE = Object.new.freeze
      private_constant :NONE

      class << self
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@settings, settings.transform_values { _1.is_a?(Array) ? _1.dup : _1 })
        end

        # The declarations as given.
        def settings = (@settings ||= DEFAULTS.transform_values { _1.is_a?(Array) ? _1.dup : _1 })

        # Default: the class name, underscored, with dots for ::.
        def suite_name(value = NONE)
          return settings[:name] = value unless value.equal?(NONE)

          settings[:name] || (name && name.split("::").map { underscore(_1) }.join("."))
        end

        # A folder (absolute, or under config.dataset_root) or a host source;
        # `version:` pins the dataset version.
        def dataset(source = NONE, version: nil)
          return settings[:dataset] if source.equal?(NONE)

          settings[:pinned_version] = version
          settings[:dataset] = source
        end

        def split(value = NONE) = setting(:split, value)

        # Use only some of the split: `ids:` or `tags_any:` (data, so versioned).
        def narrow(ids: nil, tags_any: nil)
          settings[:narrow] = { ids:, tags_any: }.compact
        end

        def subject(value = NONE, **options)
          return settings[:subject] if value.equal?(NONE) && options.empty?

          settings[:subject] = value.equal?(NONE) ? Subject.new(**options) : value
        end

        def trials(count = NONE, reduce: nil)
          settings[:reduce] = reduce unless reduce.nil?
          setting(:trials, count)
        end

        def error_retries(value = NONE) = setting(:error_retries, value)
        def concurrency(value = NONE) = setting(:concurrency, value)
        def driver(value = NONE) = setting(:driver, value)

        # Host error classes that are infrastructure, not the subject
        # (design 6.3): a failure from one is an error, out of the rate.
        # Written as sorted class names, in the version and the measure.
        def infrastructure_errors(*classes)
          return settings[:infrastructure_errors] if classes.empty?

          settings[:infrastructure_errors] = classes.flatten
        end

        def statistics(**options)
          settings[:statistics] = settings[:statistics].merge(options) unless options.empty?
          settings[:statistics]
        end

        def recording(**options)
          settings[:recording] = settings[:recording].merge(options) unless options.empty?
          settings[:recording]
        end

        # A block scorer (`scorer :name, version: 1 do |sample, trial| ... end`),
        # or a Scorer class or instance, with the reducers this suite reads it by.
        def scorer(target, version: nil, scale: nil, reduce: nil, also: nil, on_subject_failure: nil, &block)
          settings[:scorers] << { target:, block:, version:, scale:, reduce:, also:, on_subject_failure: }
        end

        # A fixed target, judged on the headline estimate's point (slice 1b);
        # in the version, never in the measure digest. `gate`, `budget` and
        # `labels` are experimental and not frozen: slice 1b.1 and slice 2
        # decide their final names.
        def gate(id, scorer:, at_least:, reducer: nil)
          settings[:gates] << { id:, scorer:, reducer:, target: at_least }
        end

        # The run's cap (slice 1b); never part of the version.
        def budget(max_cost_nanos:) = (settings[:budget] = max_cost_nanos.nil? ? nil : { max_cost_nanos: })

        # Which labels count (slice 2): :any (the default) or :human_only.
        def labels(accept:) = (settings[:labels] = { accept: })

        # The manifest (with its version), every default written out.
        def manifest(scope: nil) = SuiteManifest.build(self, scope: resolved_scope(scope))

        def version(scope: nil) = manifest(scope:).fetch("version")

        # The scorers, each with the name, reducers and failure rule the
        # manifest gives it.
        def scorers = SuiteManifest.scorers(self)

        def selection(scope: nil)
          scope = resolved_scope(scope)
          manifest = manifest(scope:)
          dataset = Dataset.load(dataset_source, scope:, version: manifest.dig("dataset", "pinned_version"))
          samples = SuiteManifest.select(dataset, manifest)
          ids = Identity.sample_ids_digest(samples.map(&:id))
          Selection.new(manifest:, dataset:, samples:, sample_ids_digest: ids,
                        measure_digest: Identity.measure_digest(manifest, dataset: dataset.version, samples: ids))
        end

        def measure_digest(scope: nil) = selection(scope:).measure_digest

        # The declared dataset as a source: a folder joined to dataset_root.
        def dataset_source
          source = settings[:dataset]
          return source unless source.is_a?(String) || source.respond_to?(:to_path)

          root = Evals.config.dataset_root
          root.nil? || File.absolute_path?(source.to_s) ? source.to_s : File.join(root, source.to_s)
        end

        private

        def setting(key, value)
          return settings[key] if value.equal?(NONE)

          settings[key] = value
        end

        def resolved_scope(scope) = Smith::Scope.build(scope || Evals.config.default_scope)

        def underscore(text)
          text.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
        end
      end
    end
  end
end
