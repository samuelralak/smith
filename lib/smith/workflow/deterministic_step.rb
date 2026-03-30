# frozen_string_literal: true

module Smith
  class Workflow
    class DeterministicStep
      attr_reader :context, :tool_results, :session_messages, :current_state, :transition_name,
                  :context_writes, :routed_to, :outcome

      def initialize(context:, session_messages:, tool_results:, state:, transition_name:)
        @context = context
        @session_messages = session_messages
        @tool_results = tool_results
        @current_state = state
        @transition_name = transition_name
        @context_writes = {}
        @routed_to = nil
        @outcome = nil
      end

      def last_output
        return @last_output if defined?(@last_output)

        msg = session_messages.reverse.find { |m| m[:role] == :assistant || m[:role] == "assistant" }
        @last_output = msg&.dig(:content)
      end

      alias_method :output, :last_output

      def read_context(key)
        @context_writes.key?(key) ? @context_writes[key] : context[key]
      end

      def write_context(key, value)
        raise WorkflowError, "write_context key must be a Symbol, got #{key.class}" unless key.is_a?(Symbol)

        @context_writes[key] = value
      end

      def route_to(transition_name)
        raise WorkflowError, "route_to already called with :#{@routed_to}" if @routed_to

        @routed_to = transition_name
      end

      def write_outcome(kind:, payload:)
        raise WorkflowError, "write_outcome kind must be a Symbol, got #{kind.class}" unless kind.is_a?(Symbol)
        raise WorkflowError, "write_outcome already called with :#{@outcome[:kind]}" if @outcome

        @outcome = { kind: kind, payload: payload }
      end

      def fail!(message, retryable: nil, kind: nil, details: nil)
        raise DeterministicStepFailure.new(message, retryable: retryable, kind: kind, details: details)
      end
    end
  end
end
