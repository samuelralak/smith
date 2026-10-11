# frozen_string_literal: true

module Smith
  # Where steps keep payloads too large to keep inline, and the documents
  # and images content parts name. Like workflow state, artifacts must
  # outlive the process that stored them whenever a run waits, retries or
  # resumes elsewhere, so the store is configured, never assumed:
  #
  #   Smith.configure do |config|
  #     config.artifact_store = :s3            # or :active_record, :file, :memory, or a store
  #     config.artifact_options = { bucket: "smith-artifacts",
  #                                 endpoint: "https://<account>.r2.cloudflarestorage.com" }
  #   end
  #
  # With nothing configured, `Smith.artifacts` raises
  # Smith::ArtifactStoreMissing, except in `test_mode`, where it is an
  # in-process Memory store.
  module Artifacts
    REQUIRED_METHODS = %i[store fetch expired].freeze
    NAMED = { memory: :Memory, file: :File, s3: :S3, active_record: :ActiveRecordStore }.freeze

    # The store a configuration names: a store itself, a store class
    # (built with the options), or one of :memory, :file, :s3 and
    # :active_record.
    def self.resolve(store, **)
      return if store.nil?
      return validate!(store.new(**)) if store.is_a?(Class)
      return validate!(store) unless store.is_a?(Symbol) || store.is_a?(String)

      name = NAMED.fetch(store.to_sym) do
        raise ArgumentError, "unknown artifact store #{store.inspect}; use :s3, :active_record, :file or :memory"
      end
      const_get(name).new(**)
    end

    def self.validate!(store)
      missing = REQUIRED_METHODS.reject { |method_name| store.respond_to?(method_name) }
      return store if missing.empty?

      raise ArgumentError, "an artifact store must implement #{missing.join(", ")}"
    end
  end

  # Inside a step, the run's scoped view of the artifact store; elsewhere
  # the store itself.
  def self.artifacts
    scoped_artifacts || artifact_backend
  end

  # The configured store itself, never a run's scoped view of it.
  def self.artifact_backend
    signature = artifact_signature
    return @_artifact_backend if @_artifact_backend && @_artifact_signature == signature

    backend = Artifacts.resolve(config.artifact_store, **(config.artifact_options || {}))
    backend ||= Artifacts::Memory.new if config.test_mode
    raise ArtifactStoreMissing unless backend

    @_artifact_signature = signature
    @_artifact_backend = backend
  end

  def self.artifact_signature
    [snapshot_value(config.artifact_store), snapshot_value(config.artifact_options || {}), config.test_mode]
  end
  private_class_method :artifact_signature

  def self.artifacts=(store)
    config.artifact_store = store
  end

  def self.scoped_artifacts
    Thread.current[:smith_scoped_artifacts]
  end

  def self.scoped_artifacts=(store)
    Thread.current[:smith_scoped_artifacts] = store
  end
end
