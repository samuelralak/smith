# frozen_string_literal: true

module Smith
  module Artifacts; end

  # Inside a step, the run's scoped view of the artifact store; elsewhere
  # the store itself.
  def self.artifacts
    scoped_artifacts || artifact_backend
  end

  # The store itself, never a run's scoped view of it.
  def self.artifact_backend
    config.artifact_store || (@_default_artifacts ||= Artifacts::Memory.new)
  end

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
