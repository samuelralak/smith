# frozen_string_literal: true

require "securerandom"

module Smith
  class Workflow
    include DSL
    include Persistence
    include GuardrailIntegration
    include BudgetIntegration
    include EventIntegration
    include ArtifactIntegration
    include DataVolumePolicy
    include DeadlineEnforcement
    include Execution

    DEFAULT_MAX_TRANSITIONS = 100

    RunResult = Struct.new(:state, :output, :steps, :total_cost, :total_tokens)

    AgentResult = Struct.new(:content, :input_tokens, :output_tokens) do
      def self.from_response(response, content)
        new(
          content,
          response.respond_to?(:input_tokens) ? response.input_tokens : nil,
          response.respond_to?(:output_tokens) ? response.output_tokens : nil
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
      @budget_consumed = {}
      @step_count = 0
      @next_transition_name = nil
      @ledger = ledger || build_ledger
      @created_at = created_at || Time.now.utc.iso8601
      @updated_at = @created_at
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
      RunResult.new(
        state: @state,
        output: steps.last&.dig(:output),
        steps: steps,
        total_cost: 0.0,
        total_tokens: 0
      )
    end

    private

    def terminal?
      self.class.transitions_from(@state).empty? && @next_transition_name.nil?
    end

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
  end
end
