# frozen_string_literal: true

require "digest"

module CoreInvisibility
  FORMAT = "smith.core_invisibility/1"
  PRICES = %w[claude-sonnet-5-5 claude-haiku-5-5].to_h do |model|
    [["anthropic", model], { input_cost_per_token: 0.000003, output_cost_per_token: 0.000015, batch_discount: 0.5 }]
  end.freeze

  Scenario = Struct.new(:name, :concurrent, :drive)

  class << self
    attr_accessor :record

    def scenarios = @scenarios ||= []

    # Declares a scenario; `concurrent:` also runs it with branches in
    # parallel, compared by counts. Later slices only add scenarios.
    def scenario(name, concurrent: false, &drive)
      raise ArgumentError, "scenario #{name} is declared twice" if scenarios.any? { _1.name == name }

      scenarios << Scenario.new(name, concurrent, drive)
    end
  end

  # A test observer for the seam: what it was handed, in order.
  class Observer
    def initialize
      @lock = Mutex.new
      @seen = []
    end

    def attempt_finished(observation) = @lock.synchronize { @seen << observation }

    def drain = @lock.synchronize { @seen.dup.tap { @seen.clear } }

    KEPT = %i[attempt_id agent model memo sent_count tool_call_names stop_reason].freeze
    NORMALIZED = %i[failure tokens position].freeze
    private_constant :KEPT, :NORMALIZED

    # What the spec checks of each observation; the messages by count.
    def self.summary(observation)
      fields = observation.to_h
      messages = fields[:messages]
      normalized = Normal.value(fields.slice(*NORMALIZED).transform_keys(&:to_s))
      fields.slice(*KEPT).transform_keys(&:to_s).merge(
        "outcome" => fields[:outcome].to_s, "mode" => fields[:mode].to_s, "messages" => messages.length,
        "roles" => messages.map { _1["role"] }, **normalized
      )
    end
  end

  # Facts about the process the document came from; none is compared.
  module Environment
    module_function

    # Where Smith came from, and which: a git source by its parts' ids and
    # the commit they were built on, a release's package by its sha256.
    def smith
      source, provenance = origin
      { "version" => Smith::VERSION, "source" => source, **provenance }
    end

    # "index" or "commit" when smith.rb came from a folder of a source's
    # parts, in the bundle built there (GitSource), holding exactly those
    # parts; "tree" when from the lib beside this harness; "release" when
    # from an installed smith-agents a rubygems source gave the bundle; and
    # "other" otherwise (another checkout, a working tree, a path or git
    # gem).
    def origin
      @origin ||= begin
        loaded = $LOADED_FEATURES.find { _1.end_with?("/lib/smith.rb") }
        loaded ? origin_of(File.realpath(loaded), Gem.loaded_specs["smith-agents"]) : ["other", {}]
      end
    end

    def source = origin.first

    # A folder of a source's parts holds this harness too, so it is
    # checked before the lib beside the harness is taken for the tree.
    def origin_of(path, spec)
      root = File.dirname(path, 2)
      folder = spec && File.realpath(spec.full_gem_path) == root && SourceFolder.of(root)
      return folder if folder
      return ["tree", {}] if path == File.realpath(File.expand_path("../../lib/smith.rb", __dir__))
      return ["release", { "sha256" => Digest::SHA256.file(spec.cache_file).hexdigest }] if released?(spec, path)

      ["other", {}]
    end

    def released?(spec, path)
      return false unless spec && path.start_with?("#{File.realpath(spec.full_gem_path)}/")

      !defined?(Bundler) || !spec.respond_to?(:source) || spec.source.is_a?(Bundler::Source::Rubygems)
    end

    def versions
      { "ruby" => RUBY_VERSION, "ruby_llm" => Gem.loaded_specs["ruby_llm"]&.version.to_s,
        "faraday" => Gem.loaded_specs["faraday"]&.version.to_s, "json" => JSON::VERSION }
    end

    def process
      seam = Smith.const_defined?(:AttemptObservation, false)
      { "evals_defined" => !defined?(Smith::Evals).nil?, "attempt_observation" => seam,
        "observer_installed" => seam && !Smith::AttemptObservation.observer.nil?,
        "empty_attribution_fields" => Smith::Attribution::EMPTY.to_fields }
    end
  end
end
