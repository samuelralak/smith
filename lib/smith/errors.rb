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
    attr_reader :retryable, :kind, :details, :new_idempotency_key, :idempotency_scope

    # `new_idempotency_key: true` declares that the failed attempt's own
    # requests took no effect, so a retry of the step that raised it sends
    # them under new keys; `idempotency_scope` is that step's position. The
    # flag is not persisted with the failure record.
    def initialize(message, retryable: nil, kind: nil, details: nil, new_idempotency_key: false, # rubocop:disable Metrics/ParameterLists
                   idempotency_scope: nil)
      unless [true, false, nil].include?(new_idempotency_key)
        raise ArgumentError, "new_idempotency_key must be true or false"
      end

      @retryable = retryable
      @kind = kind
      @details = details
      @new_idempotency_key = new_idempotency_key == true
      @idempotency_scope = idempotency_scope
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

  # An `await` step passed its deadline before `resume!` delivered its
  # event, and the transition declares no `on_timeout` route. It takes the
  # failure path (`on_failure`, or a raise) and is never retried.
  class WaitTimedOut < WorkflowError
    DETAIL_NAMES = %w[transition event deadline_at].freeze
    private_constant :DETAIL_NAMES

    attr_reader :transition, :event, :deadline_at

    def initialize(transition:, event:, deadline_at:, message: nil)
      @transition = DiagnosticText.capture(transition.to_s, max_bytes: 256)
      @event = DiagnosticText.capture(event.to_s, max_bytes: 256)
      @deadline_at = DiagnosticText.capture(deadline_at.to_s, max_bytes: 64)
      super(message || "await #{@event} on transition #{@transition} passed its deadline #{@deadline_at}")
    end

    # Kept with the failure record, so a restored run's error is still a
    # WaitTimedOut that names its wait.
    def details = { transition:, event:, deadline_at: }.freeze

    def self.from_details(details, message: nil)
      raise ArgumentError, "wait timeout details must be a Hash" unless details.is_a?(Hash)

      values = details.to_h { |key, value| [key.to_s, value] }
      unless values.keys.sort == DETAIL_NAMES.sort && values.values.all?(String)
        raise ArgumentError, "wait timeout details are invalid"
      end

      new(transition: values["transition"], event: values["event"], deadline_at: values["deadline_at"], message:)
    end
  end

  # A `compute` or `run` step that declares `routes:` finished without
  # calling `route_to`, declares no `on_success`, and did not opt into
  # `fallthrough: true`. Without this error the run would silently take the
  # first transition declared from the step's target state.
  class UnroutedDeterministicStep < WorkflowError
    attr_reader :transition, :routes

    def initialize(transition:, routes:)
      @transition = transition
      @routes = routes
      super(
        "#{DiagnosticText.capture(transition.inspect, max_bytes: 256)} declares routes: " \
        "#{DiagnosticText.capture(routes.inspect, max_bytes: 1024)} but did not call route_to; " \
        "route to one of them, declare on_success, or opt into fallthrough: true"
      )
    end
  end

  # A deterministic step wrote a context key that the workflow's
  # Smith::Context does not list in `persist :a, :b`. The write would be
  # dropped at the next checkpoint, so it fails the step instead.
  class UndeclaredContextKey < WorkflowError
    attr_reader :key, :persisted_keys

    def initialize(key:, persisted_keys:)
      @key = key
      @persisted_keys = persisted_keys
      super(
        "context key #{DiagnosticText.capture(key.inspect, max_bytes: 256)} is not a persisted context key " \
        "(persist #{DiagnosticText.capture(persisted_keys.map(&:inspect).join(", "), max_bytes: 1024)}); " \
        "declare it in the context's persist list, or use persist :auto"
      )
    end
  end

  # A step's content parts cannot be sent: a document or image is missing,
  # unreadable, empty, not what its media type says, or past a bound, or no
  # model in the chain takes it. Raised before the provider call, so it is
  # never retried as a provider failure.
  class ContentUnavailable < WorkflowError; end

  # No artifact store is configured. Artifacts must outlive the process that
  # stored them whenever a run waits, retries or resumes elsewhere, so Smith
  # assumes none outside test_mode.
  class ArtifactStoreMissing < WorkflowError
    def initialize(message = "Smith.config.artifact_store is not configured; set it to :s3, :active_record or " \
                             ":file (or a store) for runs that wait, retry or move between processes, or :memory " \
                             "for a single process")
      super
    end
  end

  # A step streams to a sink Smith.config.stream_sinks does not name.
  # Raised before the step's provider call.
  class StreamSinkMissing < WorkflowError
    def initialize(name)
      super("Smith.config.stream_sinks has no sink #{name.inspect}; register the sink the step streams to")
    end
  end

  # A step sends its request as a batch and Smith.config.batch_queue is not
  # configured. Raised before anything is sent.
  class BatchQueueMissing < WorkflowError
    def initialize(message = "Smith.config.batch_queue is not configured; batch mode hands its requests to it")
      super
    end
  end

  # A batch step's call cannot go as a batch: its model's provider has no
  # batch interface in Smith (Anthropic has), or its agent has tools (a batch
  # request is one turn). Raised before anything is sent.
  class BatchModeUnavailable < WorkflowError; end

  # A batch result that did not answer: a server error (`errored`), a
  # `canceled` or `expired` request, or none by the wait's deadline
  # (`missing`). An AgentError, so `retry_on` sends it again.
  class BatchResultFailed < AgentError
    attr_reader :kind, :error_type

    def initialize(kind:, error_type: nil)
      @kind = kind.to_s.dup.freeze
      @error_type = DiagnosticText.capture(error_type.to_s, max_bytes: 128) if error_type
      super("batch result #{@kind}#{" (#{@error_type})" if @error_type}")
    end
  end

  # The provider refused a batch request as invalid; sending it again would
  # be refused again.
  class BatchRequestInvalid < WorkflowError
    def initialize(message = "the provider refused the batch request as invalid")
      super
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

  # Raised when a persisted payload's state is not one the restoring
  # workflow class knows: neither declared with `state` nor named by any
  # transition's `from:` or `to:`. Usually a deploy renamed or removed the
  # state while a run was persisted. Restoring anyway would treat the
  # unknown state as terminal and end the run silently. Hosts bridge a
  # rename with `migrate_from`, or let the run finish on the workflow
  # version that declared the state.
  class UnknownStateOnRestore < Error
    attr_reader :workflow, :persistence_key, :state

    def initialize(workflow:, persistence_key:, state:)
      @workflow = workflow
      @persistence_key = persistence_key
      @state = state
      super(
        "unknown state #{DiagnosticText.capture(state.inspect, max_bytes: 256)} restoring #{workflow} " \
        "key=#{DiagnosticText.capture(persistence_key.inspect, max_bytes: 256)}: bump " \
        "persistence_schema_version and declare `migrate_from` to map it, or finish the run on the " \
        "workflow version that declared it."
      )
    end
  end

  # Raised when a persisted payload's pending transition is not declared by
  # the restoring workflow class, for the same reasons as
  # UnknownStateOnRestore.
  class UnknownTransitionOnRestore < Error
    attr_reader :workflow, :persistence_key, :transition

    def initialize(workflow:, persistence_key:, transition:)
      @workflow = workflow
      @persistence_key = persistence_key
      @transition = transition
      super(
        "unknown pending transition #{DiagnosticText.capture(transition.inspect, max_bytes: 256)} restoring " \
        "#{workflow} key=#{DiagnosticText.capture(persistence_key.inspect, max_bytes: 256)}: bump " \
        "persistence_schema_version and declare `migrate_from` to map it, or finish the run on the " \
        "workflow version that declared it."
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
