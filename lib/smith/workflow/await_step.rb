# frozen_string_literal: true

module Smith
  class Workflow
    # What an `await` block receives when the step is entered. It reads the
    # context, names the wait (`await_token`, the key the request the block
    # sends must carry, the same each time the block runs again after a
    # crash), and may finish the wait at once with `resolve!`. It cannot
    # write the context: the payload `resolve!` or `resume!` delivers is
    # written to the step's `into:` key.
    class AwaitStep
      attr_reader :context, :await_token, :attempt, :transition_name, :payload

      def initialize(context:, await_token:, idempotency_scope:, attempt:, transition_name:)
        @context = context
        @await_token = await_token
        @idempotency_scope = idempotency_scope
        @attempt = attempt
        @transition_name = transition_name
        @resolved = false
        @payload = nil
      end

      def read_context(key) = @context[key]

      # A key for another request the block sends, as on any step.
      def idempotency_key(scope = nil) = @idempotency_scope.key(scope)

      # Finishes the wait inline with `payload`, which is written to `into:`
      # as a delivered event's would be.
      def resolve!(payload)
        raise WorkflowError, "resolve! was already called" if @resolved

        @resolved = true
        @payload = payload
        nil
      end

      def resolved? = @resolved
    end
  end
end
