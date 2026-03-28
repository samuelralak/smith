# frozen_string_literal: true

require "securerandom"

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

    RunResult = Struct.new(:state, :output, :steps, :total_cost, :total_tokens, :context, :session_messages,
                           :tool_results) do
      def done?
        state == :done
      end

      def failed?
        state == :failed
      end

      def terminal_output
        output
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

    def build_ledger
      config = self.class.budget
      return nil unless config

      Budget::Ledger.new(limits: config)
    end

    def resolve_transition
      if @next_transition_name
        name = @next_transition_name
        @next_transition_name = nil
        self.class.find_transition(name)
      else
        self.class.transitions_from(@state).first
      end
    end

    def build_run_result(steps)
      RunResult.new(
        state: @state,
        output: steps.reverse.map { |step| step[:output] }.compact.first,
        steps: steps,
        total_cost: @total_cost,
        total_tokens: @total_tokens,
        context: snapshot_context,
        session_messages: snapshot_session_messages,
        tool_results: snapshot_tool_results
      )
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
