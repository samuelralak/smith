# frozen_string_literal: true

module Smith
  class Workflow
    class DeterministicStep
      attr_reader :context, :tool_results, :session_messages, :current_state, :transition_name,
                  :context_writes, :routed_to, :outcome, :allowed_routes, :write_violation
      # The attempt under way, from 1; above 1 only under `retry_on`.
      attr_reader :attempt

      def initialize(context:, session_messages:, tool_results:, state:, **options)
        validate_options!(options)
        transition = options[:transition]
        @context = context
        @session_messages = session_messages
        @tool_results = tool_results
        @current_state = state
        @transition_name = transition ? transition.name : options.fetch(:transition_name)
        @allowed_routes = snapshot_allowed_routes(transition ? transition.deterministic_routes : options[:allowed_routes])
        assign_execution_facts(options)
        @context_writes = {}
        @routed_to = nil
        @outcome = nil
      end

      # The model id / provider that actually served the most recent serial
      # `execute :agent` step (post fallback resolution), or nil if no serial
      # agent step has run. Symmetric with `last_output`, which returns that
      # step's content; use these to attribute an agent output to its model.
      def last_agent_model
        @last_agent_execution && @last_agent_execution[:model]
      end

      def last_agent_provider
        @last_agent_execution && @last_agent_execution[:provider]
      end

      # The output of the most recent step that produced one, whether it
      # went to the transcript or to an `output_to:` key; before any step
      # has, the last assistant message in the transcript.
      def last_output
        return @step_output unless @step_output.nil?
        return @last_output if defined?(@last_output)

        msg = session_messages.reverse.find { |m| (m[:role] || m["role"]).to_s == "assistant" }
        @last_output = msg && (msg[:content] || msg["content"])
      end

      alias_method :output, :last_output

      def read_context(key)
        @context_writes.key?(key) ? @context_writes[key] : context[key]
      end

      # The value is stored in the context's key shape at once, so a
      # `read_context` later in the same step sees what the next step will.
      # A rejected write is remembered as well as raised, so a `rescue` in
      # the step body cannot turn it into a silently dropped write.
      def write_context(key, value)
        raise WorkflowError, "write_context key must be a Symbol, got #{key.class}" unless key.is_a?(Symbol)

        if @persisted_keys && !@persisted_keys.include?(key)
          reject_write!(UndeclaredContextKey.new(key:, persisted_keys: @persisted_keys))
        end

        @context_writes[key] = begin
          ContextKeys.normalize(value)
        rescue WorkflowError => e
          reject_write!(e)
        end
      end

      def reject_write!(error)
        @write_violation ||= error
        raise error
      end

      def route_to(transition_name)
        raise WorkflowError, "route_to already called with :#{@routed_to}" if @routed_to

        @routed_to = route_target_for(transition_name)
      end

      def write_outcome(kind:, payload:)
        raise WorkflowError, "write_outcome kind must be a Symbol, got #{kind.class}" unless kind.is_a?(Symbol)
        raise WorkflowError, "write_outcome already called with :#{@outcome[:kind]}" if @outcome

        @outcome = { kind: kind, payload: payload }
      end

      def fail!(message, retryable: nil, kind: nil, details: nil, new_idempotency_key: false)
        unless [true, false, nil].include?(new_idempotency_key)
          raise ArgumentError, "fail! new_idempotency_key must be true or false"
        end

        raise DeterministicStepFailure.new(message, retryable:, kind:, details:, new_idempotency_key:,
                                                    idempotency_scope: @idempotency_scope)
      end

      # A key for a request this step sends outside the system: the same on
      # every attempt of the step and after a restore, unique to this run,
      # step and `scope`. Use a scope to tell apart several requests of one
      # step. See Smith::IdempotencyKey.
      def idempotency_key(scope = nil)
        unless @idempotency_scope
          raise WorkflowError, "an idempotency key is only available inside a running workflow step"
        end

        @idempotency_scope.key(scope)
      end

      private

      def assign_execution_facts(options)
        @last_agent_execution = options[:last_agent_execution]
        @step_output = options[:last_output]
        @persisted_keys = options[:persisted_keys]&.dup&.freeze
        @idempotency_scope = options[:idempotency_scope]
        @attempt = options.fetch(:attempt, 1)
      end

      def validate_options!(options)
        unknown = options.keys - %i[transition transition_name allowed_routes last_agent_execution last_output
                                    persisted_keys idempotency_scope attempt]
        raise ArgumentError, "unknown keywords: #{unknown.join(", ")}" if unknown.any?
        return if options[:transition] || options.key?(:transition_name)

        raise ArgumentError, "missing keyword: :transition"
      end

      def snapshot_allowed_routes(routes)
        return nil if routes.nil?

        routes.map { |route| route.is_a?(String) ? route.dup.freeze : route }.freeze
      end

      def route_target_for(transition_name)
        return transition_name if allowed_routes.nil?

        allowed_route = allowed_routes.find { |route| route == transition_name }
        return allowed_route if allowed_route

        raise WorkflowError, "route_to #{transition_name.inspect} is not declared in deterministic routes"
      end
    end
  end
end
