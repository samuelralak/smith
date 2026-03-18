# frozen_string_literal: true

require "securerandom"

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
      self.class.transitions_from(@state).empty?
    end

    def resolve_transition
      self.class.transitions_from(@state).first
    end

    def execute_step(transition)
      run_input_guardrails
      output = execute_transition_body(transition)
      run_output_guardrails(output)

      @state = transition.to
      emit_step_completed(transition, output)

      { transition: transition.name, from: transition.from, to: transition.to, output: output }
    rescue Smith::Error => e
      handle_step_failure(transition, e)
      { transition: transition.name, from: transition.from, to: transition.to, error: e }
    end

    def execute_transition_body(transition)
      return nil unless transition.agent_name

      Agent::Registry.find(transition.agent_name)
      nil
    end

    def run_input_guardrails
      wf_guardrails = self.class.guardrails
      Guardrails::Runner.run_inputs(wf_guardrails, @context) if wf_guardrails
    end

    def run_output_guardrails(output)
      wf_guardrails = self.class.guardrails
      Guardrails::Runner.run_outputs(wf_guardrails, output) if wf_guardrails
    end

    def handle_step_failure(transition, _error)
      failure_name = transition.failure_transition
      return unless failure_name

      fail_transition = self.class.instance_variable_get(:@transitions)&.fetch(failure_name, nil)
      return unless fail_transition

      @state = fail_transition.to
    end

    def emit_step_completed(_transition, _output)
      Smith::Events.emit(
        Smith::Event.new(
          execution_id: SecureRandom.uuid,
          trace_id: SecureRandom.uuid
        )
      )
    end
  end
end
