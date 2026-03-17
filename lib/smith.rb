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
  setting :trace_content, default: false
  setting :trace_retention
  setting :trace_tenant_isolation, default: false

  # Logger (§7 — Ruby Logger, not Rails.logger)
  setting :logger, default: nil

  def self.artifacts
    config.artifact_store || (@_default_artifacts ||= Artifacts::Memory.new)
  end

  def self.artifacts=(store)
    config.artifact_store = store
  end
end

# Leaf modules (no internal dependencies)
require_relative "smith/types"
require_relative "smith/errors"

# Event system (depends on Types)
require_relative "smith/event"
require_relative "smith/events"

# Budget (depends on Errors)
require_relative "smith/budget"
require_relative "smith/budget/ledger"

# Trace adapters (no internal deps)
require_relative "smith/trace"
require_relative "smith/trace/memory"
require_relative "smith/trace/logger"
require_relative "smith/trace/open_telemetry"

# Artifact store (no internal deps)
require_relative "smith/artifacts"
require_relative "smith/artifacts/memory"
require_relative "smith/artifacts/file"

# Tool (depends on RubyLLM::Tool)
require_relative "smith/tool"
require_relative "smith/tools"
require_relative "smith/tools/web_search"
require_relative "smith/tools/url_fetcher"
require_relative "smith/tools/think"

# Guardrails and Context (no internal deps)
require_relative "smith/guardrails"
require_relative "smith/guardrails/url_verifier"
require_relative "smith/context"

# Agent (depends on RubyLLM::Agent)
require_relative "smith/agent"
require_relative "smith/agent/registry"

# Workflow (Transition and Persistence must load before Workflow)
require_relative "smith/workflow/transition"
require_relative "smith/workflow/persistence"
require_relative "smith/workflow"
require_relative "smith/workflow/pipeline"
require_relative "smith/workflow/router"
require_relative "smith/workflow/parallel"
