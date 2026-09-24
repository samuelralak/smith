# frozen_string_literal: true

require_relative "diagnostic_text"
require_relative "error"
require_relative "persisted_failure_invalid"
require_relative "pricing_configuration_error"
require_relative "provider_permanent_failure"
require_relative "tool_capture_failed"
require_relative "tool_execution_not_admitted"
require_relative "tool_failure_notification_failed"

module Smith
  # Classification surface for host retry policies. Smith owns the
  # answer to "should the workflow attempt be retried?" so consumers
  # don't reimplement the case statement in every Execution / Job.
  module Errors
    MODULE_MATCH = Module.instance_method(:===)
    private_constant :MODULE_MATCH

    # Returns true when the host should retry the workflow attempt.
    # AgentError + DeadlineExceeded are always retryable.
    # DeterministicStepFailure + ToolGuardrailFailed honor their
    # `retryable` attribute (opt-in at the raise site).
    # All other Smith errors and non-Smith errors return false.
    def self.retryable?(error)
      return false if error.nil?

      composite_failure = defined?(Smith::Workflow::Composite::BranchFailure) &&
                          MODULE_MATCH.bind_call(Smith::Workflow::Composite::BranchFailure, error)
      return false if composite_failure

      case error
      when Smith::DeterministicStepFailure, Smith::ToolGuardrailFailed
        error.retryable == true
      when Smith::AgentError, Smith::DeadlineExceeded
        true
      else
        false
      end
    end

    def self.retry_forbidden?(error)
      return false if error.nil?

      retry_forbidden_classes.any? { |error_class| MODULE_MATCH.bind_call(error_class, error) }
    end

    def self.retry_forbidden_class?(error_class)
      retry_forbidden_classes.any? { |forbidden| error_class <= forbidden }
    end

    def self.retry_forbidden_classes
      @retry_forbidden_classes ||= [
        Smith::ToolCaptureFailed,
        Smith::ToolOutcomeUncertain,
        Smith::ToolExecutionNotAdmitted,
        Smith::ToolFailureNotificationFailed,
        Smith::BoundedCompletionError,
        Smith::PersistedFailureInvalid
      ].freeze
    end

    # Always-retryable error classes for explicit ActiveJob retry_on
    # allow-lists. Excludes the retryable-bearing families because
    # their retryability is per-raise, not per-class.
    def self.retryable_classes
      [Smith::AgentError, Smith::DeadlineExceeded].freeze
    end
  end

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
  class ToolDispatchRejected < Error; end
  class BoundedCompletionError < Error; end
  class ToolOutcomeUncertain < Error; end
  class AgentError < Error; end

  class BlankAgentOutputError < AgentError
    DETAIL_NAMES = %i[agent_name model_used].freeze
    DETAIL_KEYS = DETAIL_NAMES.to_h { |name| [name.to_s.freeze, name] }.freeze
    MAX_DETAIL_BYTES = 512
    private_constant :DETAIL_NAMES, :DETAIL_KEYS, :MAX_DETAIL_BYTES

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

    def details
      {
        agent_name: agent_name && DiagnosticText.capture(agent_name.to_s, max_bytes: MAX_DETAIL_BYTES),
        model_used: model_used && DiagnosticText.capture(model_used.to_s, max_bytes: MAX_DETAIL_BYTES)
      }.freeze
    end

    def self.from_details(details)
      values = normalize_details(details)
      new(agent_name: values.fetch(:agent_name)&.to_sym, model_used: values.fetch(:model_used))
    end

    def self.normalize_details(details)
      raise ArgumentError, "blank agent output details must be a Hash" unless details.is_a?(Hash)

      values = {}
      Hash.instance_method(:each_pair).bind_call(details) do |key, value|
        name = key.is_a?(Symbol) ? key : DETAIL_KEYS[key]
        unless DETAIL_NAMES.include?(name)
          raise ArgumentError, "blank agent output details contain an unknown attribute"
        end
        raise ArgumentError, "blank agent output details contain a duplicate attribute" if values.key?(name)

        values[name] = bounded_detail(name, value)
      end
      raise ArgumentError, "blank agent output details are incomplete" unless values.length == DETAIL_NAMES.length

      values
    end

    def self.bounded_detail(name, value)
      return value if value.nil?

      bounded = value.is_a?(String) && value.valid_encoding? && value.bytesize <= MAX_DETAIL_BYTES
      raise ArgumentError, "blank agent output detail #{name} must be bounded text" unless bounded

      value
    end
    private_class_method :normalize_details, :bounded_detail
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
  # double-execute non-idempotent agent calls or tools. `state` is the
  # persisted state the interrupted step started from and `transition` the
  # next transition the payload records; each is nil when unknown.
  class StepInProgressOnRestore < Error
    attr_reader :workflow, :persistence_key, :state, :transition

    def initialize(workflow:, persistence_key:, state: nil, transition: nil)
      @workflow = workflow
      @persistence_key = persistence_key
      @state = state.to_sym if state.is_a?(String) || state.is_a?(Symbol)
      @transition = transition.to_sym if transition.is_a?(String) || transition.is_a?(Symbol)
      super(
        "step in progress on restore for #{workflow} key=#{persistence_key.inspect}" \
        "#{" state=#{@state.inspect}" if @state}: " \
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
