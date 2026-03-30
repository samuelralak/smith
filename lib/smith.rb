# frozen_string_literal: true

require "dry-configurable"

require_relative "smith/version"

module Smith
  class Error < StandardError; end

  extend Dry::Configurable

  # Artifact store (§4.7)
  setting :artifact_store
  setting :artifact_retention
  setting :artifact_encryption, default: :none
  setting :artifact_tenant_isolation, default: false

  # Trace adapters (§4.8)
  setting :trace_adapter
  setting :trace_transitions, default: true
  setting :trace_tool_calls, default: true
  setting :trace_token_usage, default: true
  setting :trace_cost, default: true
  setting :trace_fields
  setting :trace_content, default: false
  setting :trace_retention
  setting :trace_tenant_isolation, default: false

  # Pricing (§4.5 — model-call cost computation)
  setting :pricing, default: nil

  # Persistence adapter for host durability verification (§doctor)
  setting :persistence_adapter, default: nil
  setting :persistence_options, default: {}.freeze

  # RubyLLM model registry mode: nil/:bundled (default) or :database (§doctor)
  setting :ruby_llm_model_registry, default: nil

  # Logger (§7 — Ruby Logger, not Rails.logger)
  setting :logger, default: nil

  def self.artifacts
    scoped_artifacts || config.artifact_store || (@_default_artifacts ||= Artifacts::Memory.new)
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

  def self.persistence_adapter
    raw_adapter = config.persistence_adapter
    raw_options = config.persistence_options || {}
    signature = persistence_signature(raw_adapter, raw_options)

    if defined?(@_persistence_adapter_signature) && @_persistence_adapter_signature == signature
      return @_persistence_adapter
    end

    @_persistence_adapter_signature = signature
    @_persistence_adapter = PersistenceAdapters.resolve(raw_adapter, **raw_options)
  end

  def self.persistence_signature(adapter, options)
    [snapshot_value(adapter), snapshot_value(options)]
  end
  private_class_method :persistence_signature

  def self.snapshot_value(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, nested), copy|
        copy[snapshot_value(key)] = snapshot_value(nested)
      end.freeze
    when Array
      value.map { |nested| snapshot_value(nested) }.freeze
    when String
      value.dup.freeze
    else
      value
    end
  end
  private_class_method :snapshot_value
end

# Leaf modules (no internal dependencies)
require_relative "smith/types"
require_relative "smith/errors"

# Event system (depends on Types)
require_relative "smith/event"
require_relative "smith/events"
require_relative "smith/events/subscription"
require_relative "smith/events/bus"
require_relative "smith/events/step_completed"

# Budget (depends on Errors)
require_relative "smith/budget"
require_relative "smith/budget/ledger"

# Pricing (depends on Smith config)
require_relative "smith/pricing"

# Trace adapters (no internal deps)
require_relative "smith/trace"
require_relative "smith/trace/memory"
require_relative "smith/trace/logger"
require_relative "smith/trace/open_telemetry"

# Artifact store (no internal deps)
require_relative "smith/artifacts"
require_relative "smith/artifacts/memory"
require_relative "smith/artifacts/file"
require_relative "smith/artifacts/scoped_store"

# Host persistence adapters (no internal deps)
require_relative "smith/persistence_adapters"

# Tool (depends on RubyLLM::Tool)
require_relative "smith/tool"
require_relative "smith/tools"
require_relative "smith/tools/web_search"
require_relative "smith/tools/url_fetcher"
require_relative "smith/tools/think"

# Guardrails and Context (no internal deps)
require_relative "smith/guardrails"
require_relative "smith/guardrails/runner"
require_relative "smith/guardrails/url_verifier"
require_relative "smith/context"
require_relative "smith/context/observation_masking"
require_relative "smith/context/state_injection"
require_relative "smith/context/session"

# Agent (depends on RubyLLM::Agent)
require_relative "smith/agent"
require_relative "smith/agent/lifecycle"
require_relative "smith/agent/registry"

# Workflow (Transition, DSL, Persistence, and Execution must load before Workflow)
require_relative "smith/workflow/transition"
require_relative "smith/workflow/dsl"
require_relative "smith/workflow/persistence"
require_relative "smith/workflow/durability"
require_relative "smith/workflow/guardrail_integration"
require_relative "smith/workflow/budget_integration"
require_relative "smith/workflow/event_integration"
require_relative "smith/workflow/artifact_integration"
require_relative "smith/workflow/data_volume_policy"
require_relative "smith/workflow/deadline_enforcement"
require_relative "smith/workflow/nested_execution"
require_relative "smith/workflow/evaluator_optimizer"
require_relative "smith/workflow/orchestrator_worker"
require_relative "smith/workflow/parallel_execution"
require_relative "smith/workflow/deterministic_step"
require_relative "smith/workflow/deterministic_execution"
require_relative "smith/workflow/execution"
require_relative "smith/workflow"
require_relative "smith/workflow/pipeline"
require_relative "smith/workflow/router"
require_relative "smith/workflow/parallel"

# Conditional Rails integration
require_relative "smith/railtie" if defined?(Rails::Railtie)
