# frozen_string_literal: true

module Smith
  class Workflow
    include DSL
    include Persistence

    DEFAULT_MAX_TRANSITIONS = 100

    RunResult = Struct.new(:state, :output, :steps, :total_cost, :total_tokens)

    attr_reader :state

    def initialize(context: {})
      @state = self.class.initial_state
      @context = context
      @budget_consumed = {}
      @step_count = 0
      @created_at = Time.now.utc.iso8601
      @updated_at = @created_at
    end

    def advance!
      max = self.class.max_transitions || DEFAULT_MAX_TRANSITIONS
      raise MaxTransitionsExceeded if @step_count >= max

      @step_count += 1
      @updated_at = Time.now.utc.iso8601
    end

    def run!
      steps = []
      advance! until terminal?
      RunResult.new(
        state: @state,
        output: steps.last,
        steps: steps,
        total_cost: 0.0,
        total_tokens: 0
      )
    end

    private

    def terminal?
      true
    end
  end
end
