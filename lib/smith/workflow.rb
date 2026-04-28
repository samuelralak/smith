# frozen_string_literal: true

require "securerandom"
require "time"

module Smith
  class Workflow
    include DSL
    include Persistence
    include Durability
    include GuardrailIntegration
    include BudgetIntegration
    include EventIntegration
    include ArtifactIntegration
    include DataVolumePolicy
    include DeadlineEnforcement
    include Execution

    DEFAULT_MAX_TRANSITIONS = 100

    # `keyword_init: true` is mandatory: `build_run_result` constructs
    # the result via keyword arguments. Plain Ruby Structs treat the
    # kwargs hash as the first positional field, silently leaving the
    # remaining fields nil — verified empirically. The `keyword_init`
    # flag routes kwargs to the right fields. `usage_entries` is the
    # 10th field, added in this slice for hadithi billing.
    RunResult = Struct.new(:state, :output, :steps, :total_cost, :total_tokens, :context, :session_messages,
                           :tool_results, :outcome, :usage_entries, keyword_init: true) do
      def done?
        state == :done
      end

      def failed?
        state == :failed
      end

      def terminal_output
        output
      end

      def outcome_kind
        outcome&.dig(:kind)
      end

      def outcome_payload
        outcome&.dig(:payload)
      end

      def last_error
        steps.reverse.map { |step| step[:error] }.compact.first
      end

      def failed_transition
        failure_detail&.fetch(:transition)
      end

      def failure_detail
        failed_step = steps.reverse.find { |step| step[:error] }
        return nil unless failed_step

        {
          transition: failed_step[:transition],
          from: failed_step[:from],
          to: failed_step[:to],
          error: failed_step[:error]
        }
      end
    end

    AgentResult = Struct.new(:content, :input_tokens, :output_tokens, :cost, :model_used) do
      def self.from_response(response, content, model_used: nil)
        new(
          content,
          response.respond_to?(:input_tokens) ? response.input_tokens : nil,
          response.respond_to?(:output_tokens) ? response.output_tokens : nil,
          nil,
          model_used
        )
      end

      def usage_known?
        !input_tokens.nil? && !output_tokens.nil?
      end
    end

    # One row per agent provider call. `usage_id` is a UUID generated
    # at recording time and stable across persist/restore — hadithi
    # uses it as the idempotency anchor on `usage_events.smith_usage_id`.
    # Includes `to_h`/`from_h` for JSON serialization (plain Struct
    # JSON-encodes to `"#<struct ...>"` — useless).
    UsageEntry = Struct.new(
      :usage_id,
      :agent_name,
      :model,
      :input_tokens,
      :output_tokens,
      :cost,
      :attempt_kind,
      :recorded_at
    ) do
      def to_h
        members.zip(values).to_h
      end

      def self.from_h(hash)
        sym = hash.transform_keys(&:to_sym)
        new(
          sym[:usage_id],
          sym[:agent_name]&.to_sym,
          sym[:model],
          sym[:input_tokens],
          sym[:output_tokens],
          sym[:cost],
          sym[:attempt_kind]&.to_sym,
          sym[:recorded_at]
        )
      end
    end

    # Reconstruct Smith error classes from `@last_failed_step` snapshots.
    # Order matters: more-specific subclasses first, so a real DSF doesn't
    # get caught by the WorkflowError handler. Each lambda preserves the
    # billing-critical attributes (`retryable`, `kind`, `details`) by
    # routing through the original constructor — Smith's retryable errors
    # expose `attr_reader :retryable` only, with no setter, so kwargs
    # MUST flow through `initialize`.
    KNOWN_RECONSTRUCTORS = {
      "Smith::ToolGuardrailFailed" => ->(s) {
        Smith::ToolGuardrailFailed.new(s[:error_message], retryable: s[:error_retryable])
      },
      "Smith::DeterministicStepFailure" => ->(s) {
        Smith::DeterministicStepFailure.new(
          s[:error_message],
          retryable: s[:error_retryable],
          kind:      s[:error_kind],
          details:   s[:error_details]
        )
      },
      "Smith::AgentError"        => ->(s) { Smith::AgentError.new(s[:error_message]) },
      "Smith::DeadlineExceeded"  => ->(s) { Smith::DeadlineExceeded.new(s[:error_message]) },
      "Smith::WorkflowError"     => ->(s) { Smith::WorkflowError.new(s[:error_message]) },
      # Smith errors with non-message constructors map to compatible
      # superclass — message preserved, original metadata (agent_name,
      # model_used, requested_name, workflow_class, origin_state) lossy
      # but `is_a?` classification round-trips via the superclass.
      "Smith::BlankAgentOutputError"     => ->(s) { Smith::AgentError.new(s[:error_message]) },
      "Smith::UnresolvedTransitionError" => ->(s) { Smith::WorkflowError.new(s[:error_message]) }
    }.freeze
    private_constant :KNOWN_RECONSTRUCTORS

    # Families whose retryable/kind/details attributes are billing-critical.
    # For these, the reconstruction path bypasses `const_get(...).new(message)`
    # (which would succeed for unknown subclasses with message-only
    # constructors but discard the kwargs) and uses the family fallback
    # directly so the parent-class constructor preserves the attrs.
    RETRYABLE_BEARING_FAMILIES = %w[deterministic_step_failure tool_guardrail_failed].freeze
    private_constant :RETRYABLE_BEARING_FAMILIES

    BranchEnv = Struct.new(:prepared_input, :guardrail_sources, :scoped_store, :branch_estimates, :deadline) do
      def setup_thread
        Smith::Tool.current_guardrails = guardrail_sources
        Smith::Tool.current_deadline = deadline
        Smith.scoped_artifacts = scoped_store
      end

      def teardown_thread
        Smith::Tool.current_guardrails = nil
        Smith::Tool.current_deadline = nil
        Smith.scoped_artifacts = nil
      end
    end

    attr_reader :state, :last_prepared_input, :session_messages, :ledger

    def initialize(context: {}, ledger: nil, created_at: nil)
      @state = self.class.initial_state
      @context = context
      @step_count = 0
      @next_transition_name = nil
      @ledger = ledger || build_ledger
      @created_at = created_at || Time.now.utc.iso8601
      @updated_at = @created_at
      @total_cost = 0.0
      @total_tokens = 0
      @outcome = nil
      # Eager init for usage tracking. Both `@usage_mutex` (lazy
      # init at the call site would race across parallel fan-out
      # branches) and the durable per-call/output/failure fields
      # must be present before any agent recording fires.
      # `restore_state` mirrors these inits because `from_state` uses
      # `allocate` and bypasses `initialize` — see persistence.rb.
      @usage_entries = []
      @usage_mutex = Mutex.new
      @last_output = nil
      @last_failed_step = nil
      initialize_tool_result_state
      seed_initial_session_messages
    end

    def advance!
      max = self.class.max_transitions || DEFAULT_MAX_TRANSITIONS
      raise MaxTransitionsExceeded if @step_count >= max

      transition = resolve_transition
      return if transition.nil?

      step_result = execute_step(transition)
      @step_count += 1
      @updated_at = Time.now.utc.iso8601
      record_step_snapshot(step_result)
      step_result
    rescue UnresolvedTransitionError => e
      origin_state = @state
      @outcome = nil
      raise unless route_to_fail_state!

      step_result = { transition: e.requested_name, from: origin_state, to: @state, error: e }
      record_step_snapshot(step_result)
      step_result
    end

    def run!
      steps = []
      until terminal?
        step = advance!
        steps << step if step
      end
      build_run_result(steps)
    end

    def terminal?
      self.class.transitions_from(@state).empty? && @next_transition_name.nil?
    end

    def done?
      @state == :done
    end

    def failed?
      @state == :failed
    end

    private

    # Centralized capture for both `advance!` paths — the normal
    # `execute_step` return AND the `UnresolvedTransitionError` rescue
    # path. Without centralization, the rescue path's step would never
    # populate `@last_failed_step`, and an unresolved-transition
    # terminal failure restored after persist would have nil last_error.
    #
    # On a successful step (no :error key, possibly with :output): clear
    # `@last_failed_step` (a workflow that handled a failure and reached
    # :done shouldn't synthesize a stale error on terminal restore) and
    # capture the latest non-nil `:output` into `@last_output` (last
    # non-nil wins; matches `RunResult#output`'s `compact.first` shape).
    def record_step_snapshot(step_result)
      return unless step_result

      if step_result[:error]
        err = step_result[:error]
        # error_family preserves classification across reconstruction
        # even when the exact class can't be rebuilt. Order matters:
        # specific subclasses first (DSF before WorkflowError, etc.)
        # so a real DSF doesn't get classified as workflow_error.
        error_family = case err
                       when Smith::DeterministicStepFailure then "deterministic_step_failure"
                       when Smith::ToolGuardrailFailed      then "tool_guardrail_failed"
                       when Smith::DeadlineExceeded         then "deadline_exceeded"
                       when Smith::AgentError               then "agent_error"
                       when Smith::WorkflowError            then "workflow_error"
                       else                                       "other"
                       end
        @last_failed_step = {
          transition: step_result[:transition],
          from: step_result[:from],
          to: step_result[:to],
          error_class: err.class.name,
          error_family: error_family,
          error_message: err.message,
          error_retryable: err.respond_to?(:retryable) ? err.retryable : nil,
          error_kind:      err.respond_to?(:kind)      ? err.kind      : nil,
          error_details:   err.respond_to?(:details)   ? err.details   : nil
        }
      else
        # Successful step: clear any prior failed-step snapshot
        # (workflow handled the failure and continued) and capture
        # the output if non-nil (preserves `false` as a valid output;
        # matches `RunResult#output`'s `.compact.first` semantics).
        @last_failed_step = nil
        @last_output = step_result[:output] if step_result.key?(:output) && !step_result[:output].nil?
      end
    end

    def build_ledger
      config = self.class.budget
      return nil unless config

      Budget::Ledger.new(limits: config)
    end

    def route_to_fail_state!
      fail_transition = self.class.find_transition(:fail)
      return false unless fail_transition

      @state = fail_transition.to
      true
    end

    def resolve_transition
      if @next_transition_name
        name = @next_transition_name
        @next_transition_name = nil
        self.class.find_transition(name) ||
          raise(UnresolvedTransitionError.new(name, self.class, @state))
      else
        self.class.transitions_from(@state).first
      end
    end

    def build_run_result(steps)
      # `output` derivation matches existing semantics on fresh runs
      # (last non-nil step output via `compact.first`). Terminal-restore
      # path (steps.empty?) falls back to `@last_output` so the durable
      # output survives persist/restore. Gate on `steps.empty?` to avoid
      # leaking a stale `@last_output` into a fresh run that produced
      # nil output.
      output = steps.reverse.map { |step| step[:output] }.compact.first
      output = @last_output if output.nil? && steps.empty?

      # On terminal-restore of a failed workflow with empty steps,
      # synthesize a single-step array from `@last_failed_step` so
      # `RunResult#last_error` and `#failure_detail` work exactly as
      # they do on fresh-run failures. Gate on `failed?` so a `:done`
      # terminal state never produces a synthetic error even if the
      # snapshot wasn't cleared.
      effective_steps = if steps.empty? && failed? && @last_failed_step
        [reconstruct_failed_step]
      else
        steps
      end

      RunResult.new(
        state: @state,
        output: output,
        steps: effective_steps,
        total_cost: @total_cost,
        total_tokens: @total_tokens,
        context: snapshot_context,
        session_messages: snapshot_session_messages,
        tool_results: snapshot_tool_results,
        outcome: snapshot_outcome,
        usage_entries: snapshot_usage_entries
      )
    end

    def reconstruct_failed_step
      snap = @last_failed_step
      builder = KNOWN_RECONSTRUCTORS[snap[:error_class]]
      error = if builder
        builder.call(snap)
      elsif RETRYABLE_BEARING_FAMILIES.include?(snap[:error_family])
        # Skip const_get for retryable-bearing families. An unknown
        # subclass with a message-only constructor would const_get
        # successfully but discard the snapshot's `retryable`/`kind`/
        # `details` (defaults to nil), and hadithi's `retryable?`
        # check would misclassify a retryable failure as terminal.
        # Family fallback rebuilds the parent class with kwargs intact.
        family_fallback(snap)
      else
        # Unknown subclass without retryable-bearing semantics. Try
        # the exact class for shape preservation; fall back via family
        # if the constructor doesn't accept message-only args (or the
        # class doesn't exist).
        begin
          Kernel.const_get(snap[:error_class]).new(snap[:error_message])
        rescue NameError, ArgumentError
          family_fallback(snap)
        end
      end

      # Symbol coercion on the way out: live steps carry these as
      # symbols; JSON round-trip stringifies them; coerce back to
      # match fresh-run shape exactly.
      {
        transition: snap[:transition]&.to_sym,
        from:       snap[:from]&.to_sym,
        to:         snap[:to]&.to_sym,
        error:      error
      }
    end

    def family_fallback(snap)
      case snap[:error_family]
      when "deterministic_step_failure"
        Smith::DeterministicStepFailure.new(
          snap[:error_message],
          retryable: snap[:error_retryable],
          kind:      snap[:error_kind],
          details:   snap[:error_details]
        )
      when "tool_guardrail_failed"
        Smith::ToolGuardrailFailed.new(snap[:error_message], retryable: snap[:error_retryable])
      when "deadline_exceeded" then Smith::DeadlineExceeded.new(snap[:error_message])
      when "agent_error"       then Smith::AgentError.new(snap[:error_message])
      when "workflow_error"    then Smith::WorkflowError.new(snap[:error_message])
      else                          RuntimeError.new(snap[:error_message])
      end
    end

    def seed_initial_session_messages
      builder = self.class.seed_messages
      return unless builder

      seeded = if builder.arity == 1
        builder.call(@context)
      else
        builder.call
      end

      @session_messages = normalize_seed_messages(seeded)
    end

    def normalize_seed_messages(seeded)
      return [] if seeded.nil?
      return [seeded] if seeded.is_a?(Hash)
      return seeded.to_a if seeded.respond_to?(:to_a)

      raise WorkflowError, "seed_messages must return a message Hash or an Array of message Hashes"
    end

    def snapshot_context
      snapshot_value(@context)
    end

    def snapshot_session_messages
      snapshot_value(@session_messages || [])
    end

    def snapshot_tool_results
      snapshot_value(@tool_results || [])
    end

    def snapshot_outcome
      snapshot_value(@outcome)
    end

    # Defensive deep copy via `from_h(snapshot_value(to_h))` round-trip.
    # `Struct#dup` is shallow — it shares mutable string fields between
    # the original and the duplicate. Smith's existing snapshot helpers
    # (`snapshot_context`, etc.) also use this round-trip pattern; the
    # billing-facing RunResult must not alias mutable workflow state.
    # Same rule applies to nested-workflow rollup (see
    # `nested_execution.rb`).
    def snapshot_usage_entries
      @usage_entries.map { |entry| Workflow::UsageEntry.from_h(snapshot_value(entry.to_h)) }
    end

    def tool_result_collector
      ->(entry) { @tool_results_mutex.synchronize { @tool_results << entry } }
    end

    def initialize_tool_result_state
      @tool_results = []
      @tool_results_mutex = Mutex.new
    end

    def snapshot_value(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), copy|
          copy[snapshot_value(key)] = snapshot_value(nested)
        end
      when Array
        value.map { |nested| snapshot_value(nested) }
      when String
        value.dup
      else
        value.dup
      end
    rescue TypeError
      value
    end
  end
end
