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
    REQUIRED_METHODS = %i[store fetch].freeze
    NAMED = { memory: :Memory, file: :File, s3: :S3, active_record: :ActiveRecordStore }.freeze

    # The store a configuration names: a store itself (an object, or a
    # class or module whose own methods store and fetch), a store class
    # (built with the options), or one of :memory, :file, :s3 and
    # :active_record. A store needs `store` and `fetch`; `stored_by?` lets
    # runs read only their own refs, and `expired` and `delete` serve
    # cleanup.
    def self.resolve(store, **)
      return if store.nil?
      return store if REQUIRED_METHODS.all? { |method_name| store.respond_to?(method_name) }
      return validate!(store.new(**)) if store.is_a?(Class)
      return validate!(store) unless store.is_a?(Symbol) || store.is_a?(String)

      named(store, **)
    end

    def self.named(store, **)
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
  # Built once per configuration, under a lock, so threads that resolve it
  # together share one store.
  def self.artifact_backend
    signature = artifact_signature
    current = @_artifact_current
    return current.last if current&.first == signature

    (@_artifact_lock ||= Mutex.new).synchronize do
      current = @_artifact_current
      return current.last if current&.first == signature

      @_artifact_current = [signature, build_artifact_backend].freeze
      @_artifact_current.last
    end
  end

  def self.build_artifact_backend
    resolved = Artifacts.resolve(config.artifact_store, **(config.artifact_options || {}))
    resolved ||= Artifacts::Memory.new if config.test_mode
    resolved || raise(ArtifactStoreMissing)
  end
  private_class_method :build_artifact_backend

  # A configured store object is compared by identity; a name or class by
  # value, with its options; test_mode matters only when nothing is set.
  def self.artifact_signature
    store = config.artifact_store
    name = store.is_a?(Symbol) || store.is_a?(String) || store.is_a?(Module) ? snapshot_value(store) : store.object_id
    [name, snapshot_value(config.artifact_options || {}), store.nil? && config.test_mode]
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
