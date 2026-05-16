# frozen_string_literal: true

module Smith
  module Errors; end

  class BudgetExceeded < Error; end
  class DeadlineExceeded < Error; end
  class MaxTransitionsExceeded < Error; end
  class GuardrailFailed < Error; end
  class ToolGuardrailFailed < Error
    attr_reader :retryable

    def initialize(message, retryable: nil)
      @retryable = retryable
      super(message)
    end
  end
  class ToolPolicyDenied < Error; end
  class AgentError < Error; end
  class BlankAgentOutputError < AgentError
    attr_reader :agent_name, :model_used

    def initialize(agent_name:, model_used:)
      @agent_name = agent_name
      @model_used = model_used

      detail = +"agent"
      detail << " :#{agent_name}" if agent_name
      detail << " returned blank output"
      detail << " from model #{model_used}" if model_used

      super(detail)
    end
  end
  class WorkflowError < Error; end

  class DeterministicStepFailure < WorkflowError
    attr_reader :retryable, :kind, :details

    def initialize(message, retryable: nil, kind: nil, details: nil)
      @retryable = retryable
      @kind = kind
      @details = details
      super(message)
    end
  end

  class UnresolvedTransitionError < WorkflowError
    attr_reader :requested_name, :workflow_class, :origin_state

    def initialize(requested_name, workflow_class, origin_state)
      @requested_name = requested_name
      @workflow_class = workflow_class
      @origin_state = origin_state
      super("unresolved transition :#{requested_name} in #{workflow_class} from state :#{origin_state}")
    end
  end

  class SerializationError < Error; end
  class AgentRegistryError < Error; end

  # Raised after persistence retry attempts are exhausted. Wraps the
  # underlying I/O cause (Redis connection error, AR connection error,
  # cache backend error) so hosts can distinguish a true I/O failure
  # from a programmatic error.
  class PersistenceIOError < Error
    attr_reader :operation, :cause

    def initialize(operation:, cause:)
      @operation = operation
      @cause = cause
      super("persistence I/O error during #{operation}: #{cause.class}: #{cause.message}")
    end
  end

  # Raised when an adapter's optimistic-lock check detects a concurrent
  # write: another process modified the key between this process's
  # restore and persist. Hosts can rescue + restore + retry, or fail
  # the workflow run with explicit conflict semantics.
  class PersistenceVersionConflict < Error
    attr_reader :key, :expected, :actual

    def initialize(key:, expected:, actual:)
      @key = key
      @expected = expected
      @actual = actual
      super("persistence version conflict for #{key.inspect}: expected v#{expected}, got #{actual.inspect}")
    end
  end

  # Raised when restore detects that the workflow's seed_messages
  # builder now produces a different digest than what was persisted
  # (i.e., the system prompt or seed template changed in code after this
  # workflow was already running). Only fires when the workflow opts into
  # `seed_validation :strict`; the default `:off` skips validation and
  # `:warn` logs without raising.
  class SeedMismatch < Error
    attr_reader :workflow, :stored_digest, :current_digest

    def initialize(workflow:, stored_digest:, current_digest:)
      @workflow = workflow
      @stored_digest = stored_digest
      @current_digest = current_digest
      super(
        "seed_messages drift detected for #{workflow}: stored digest #{stored_digest.inspect}, " \
        "current digest #{current_digest.inspect}. The seed_messages block changed after this " \
        "workflow was persisted. Restoring this state would mix old + new prompt context."
      )
    end
  end

  # Raised on restore when the persisted payload has the
  # step_in_progress marker set AND the workflow class opted into
  # `idempotency_mode :strict`. Signals that a previous worker crashed
  # between `persist!` (before advance) and `persist!` (after advance);
  # the step's effects are unknown, so blindly re-running could
  # double-execute non-idempotent agent calls or tools.
  class StepInProgressOnRestore < Error
    attr_reader :workflow, :persistence_key

    def initialize(workflow:, persistence_key:)
      @workflow = workflow
      @persistence_key = persistence_key
      super(
        "step in progress on restore for #{workflow} key=#{persistence_key.inspect}: " \
        "a previous worker crashed mid-step. Hosts using idempotency_mode :strict must " \
        "decide whether to clear the persisted state (idempotent re-run unsafe) or " \
        "switch to :lax (assume re-run is safe)."
      )
    end
  end

  # Raised when restoring a persisted payload whose schema_version does
  # not match the workflow's current persistence_schema_version AND no
  # migration block is registered to bridge the gap. Hosts fix this by
  # adding `migrate_from(stored) do |payload| ... end` to the workflow
  # class, or by bumping persistence_schema_version to match the stored
  # version. Downgrades (stored > current) always raise; Smith has no
  # rollback semantics.
  class PersistenceSchemaMismatch < Error
    attr_reader :workflow, :stored, :current

    def initialize(workflow:, stored:, current:)
      @workflow = workflow
      @stored = stored
      @current = current
      super(format_message(workflow, stored, current))
    end

    private

    def format_message(workflow, stored, current)
      base = "schema mismatch restoring #{workflow}: stored v#{stored}, current v#{current}."
      if stored > current
        base + " Downgrade is not supported (stored state is ahead of the current code). " \
               "Bump persistence_schema_version to at least #{stored} or roll the code forward."
      else
        base + " Declare `migrate_from(#{stored})` to bridge the gap, or bump persistence_schema_version " \
               "back to #{stored} if this version was rolled out by mistake."
      end
    end
  end
end
