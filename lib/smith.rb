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

  # Persistence TTL in Integer seconds. nil (default) means workflows
  # persist indefinitely. Adapters that natively support TTL (Redis,
  # CacheStore, Memory) pass this through; ActiveRecordStore TTL is
  # deferred (would need an `expires_at` column + sweeper).
  # Per-workflow `Workflow.persistence_ttl 1.day.to_i` DSL overrides this.
  setting :persistence_ttl, default: nil

  # Retry policy for transient persistence I/O failures.
  #   attempts:    total attempts (including the first)
  #   base_delay:  initial sleep between attempts, doubled each retry
  #   max_delay:   cap on per-retry sleep
  setting :persistence_retry_policy, default: { attempts: 3, base_delay: 0.1, max_delay: 1.0 }

  # Test isolation: when true AND persistence_adapter is nil, Smith
  # auto-selects the in-process Memory adapter. Lets specs avoid wiring
  # Redis/Rails.cache in spec_helper.rb.
  setting :test_mode, default: false

  # RubyLLM model registry mode: nil/:bundled (default) or :database (§doctor)
  setting :ruby_llm_model_registry, default: nil

  # OpenAI API mode controls Smith's vendored /v1/responses routing
  # for gpt-5 family + tools + reasoning_effort. :auto routes
  # automatically when the combo is detected; :off disables routing
  # (Smith's normalizer falls back to dropping incompatible tools).
  #
  # Default :auto reflects the "use both when possible" design intent.
  # Smith ships the Responses adapter vendored from crmne/ruby_llm PR #770
  # at a pinned SHA, so the routing path is operational for sync
  # completions. Streaming over /v1/responses is not yet supported and
  # raises NotImplementedError; hosts who need streaming with the
  # (gpt-5 + tools + thinking) combo should set openai_api_mode = :off
  # for graceful tool-dropping via chat-completions.
  setting :openai_api_mode, default: :auto, constructor: lambda { |value|
    unless %i[off auto].include?(value)
      raise ArgumentError, "Smith.config.openai_api_mode must be :off or :auto, got #{value.inspect}"
    end
    value
  }

  # Trace gating for normalizer decision events. Hosts can opt out
  # of the per-mutation event stream (the normalizer can emit several
  # events per chat construction if multiple capabilities translate).
  setting :trace_normalizer, default: true

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
    signature = persistence_signature(raw_adapter, raw_options, config.test_mode)

    if defined?(@_persistence_adapter_signature) && @_persistence_adapter_signature == signature
      return @_persistence_adapter
    end

    @_persistence_adapter_signature = signature
    @_persistence_adapter = resolve_persistence_adapter(raw_adapter, raw_options)
  end

  # Test isolation auto-detect: when no adapter is configured AND
  # test_mode is on, fall back to the in-process Memory adapter so spec
  # suites don't need to wire Redis/Rails.cache in spec_helper.rb.
  # Explicit adapter config always wins over this auto-detect.
  def self.resolve_persistence_adapter(raw_adapter, raw_options)
    return PersistenceAdapters.resolve(raw_adapter, **raw_options) if raw_adapter
    return PersistenceAdapters::Memory.new if config.test_mode

    nil
  end
  private_class_method :resolve_persistence_adapter

  def self.persistence_signature(adapter, options, test_mode)
    [snapshot_value(adapter), snapshot_value(options), test_mode]
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

# Model capability registry + pattern-based inference (depends on Errors).
# Smith ships NO specific model_id declarations. Inference rules describe
# PROVIDER FAMILIES (Anthropic Opus 4.7+ adaptive, gpt-5 family
# responses-route, Gemini 2.5+ budget_tokens). Applications register
# Smith::Models.register(Profile.new(...)) overrides only for custom
# models. Loaded BEFORE Tool so Tools that declare `compatible_with` can
# resolve capability semantics, AND before Agent so the chat override
# can call Smith::Models.find_or_infer on first construction.
require_relative "smith/models/profile"
require_relative "smith/models"
require_relative "smith/models/inference"
require_relative "smith/models/normalizer"

# OpenAI /v1/responses routing prepend. Dormant until
# Smith.config.openai_api_mode = :auto (default :off). Full
# payload assembly (Smith::Providers::OpenAI::Responses) and tool
# format helpers (Smith::Providers::OpenAI::ToolsExtensions) are
# vendored from crmne/ruby_llm PR #770 at pinned SHA. They retire when
# the PR merges upstream (Smith bumps the ruby_llm dep + deletes the
# vendored files). The require order must keep the helpers (ToolsExtensions)
# loaded BEFORE Responses since Responses calls into ToolsExtensions,
# and BOTH must load before Routing since Routing dispatches to
# Responses.complete via `defined?(...)` guard.
require_relative "smith/providers/openai/tools_extensions"
require_relative "smith/providers/openai/responses"
require_relative "smith/providers/openai/routing"

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
require_relative "smith/workflow/execution_frame"
require_relative "smith/workflow/pipeline"
require_relative "smith/workflow/router"
require_relative "smith/workflow/parallel"

# Conditional Rails integration
require_relative "smith/railtie" if defined?(Rails::Railtie)
