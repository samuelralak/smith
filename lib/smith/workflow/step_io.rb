# frozen_string_literal: true

require_relative "message_value_normalizer"

module Smith
  class Workflow
    # Per-step input and output: a step's `input:` replaces the session
    # transcript as its messages, `output_to:` writes its output to a context
    # key instead of the transcript, and an isolated session keeps no
    # transcript for agents at all.
    module StepIO
      INPUT_ROLES = %w[user assistant].freeze
      private_constant :INPUT_ROLES

      private

      def isolated_session? = self.class.session == :isolated

      # The messages an agent step sees: its `input:`, or else the session
      # transcript (with injected state), which an isolated session refuses.
      def step_prepared_input(transition)
        return step_input_messages(transition) if transition.step_input
        return build_session&.prepare! unless isolated_session? && agent_step?(transition)

        raise WorkflowError, "transition #{DiagnosticText.capture(transition.name.to_s, max_bytes: 256)} runs an " \
                             "agent in an isolated session and must declare input:"
      end

      def agent_step?(transition)
        !transition.agent_name.nil? || transition.optimized? || transition.orchestrated? || transition.fanout?
      end

      # A non-empty Array of user and assistant messages, bounded and
      # JSON-shaped like session messages. The callable gets a copy of the
      # context, so it cannot change the run's.
      def step_input_messages(transition)
        messages = transition.step_input.call(snapshot_value(@context))
        unless messages.is_a?(Array) && !messages.empty?
          raise WorkflowError, "input: must return a non-empty Array of messages"
        end

        MessageValueNormalizer.new(messages, label: "step input").call.map { |message| step_input_message(message) }
      end

      def step_input_message(message)
        unless message.is_a?(Hash) && message.keys.sort == %w[content role] && INPUT_ROLES.include?(message["role"])
          raise WorkflowError, "each input: message must be { role: :user or :assistant, content: }"
        end

        { role: message["role"].to_sym, content: message["content"] }
      end

      # The step's output, in the context's key shape, under `output_to:`;
      # an explicit persist list must allow the key.
      def deliver_output_to(transition, output)
        key = transition.output_to
        keys = declared_persist_keys
        raise UndeclaredContextKey.new(key:, persisted_keys: keys) if keys && !keys.include?(key)

        @context[key] = ContextKeys.normalize(snapshot_value(output))
        record_persisted_key!(key)
      end

      def transcript_output?(transition) = transition.output_to.nil? && !isolated_session?
    end
  end
end
