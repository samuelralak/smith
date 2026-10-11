# frozen_string_literal: true

require_relative "execution_result_snapshot"
require_relative "message_batch"
require_relative "message_value_normalizer"

module Smith
  class Workflow
    # Per-step input and output: a step's `input:` replaces the session
    # transcript as its messages, `output_to:` writes its output to a context
    # key instead of the transcript, and an isolated session keeps no
    # transcript for agents at all. Also the run's untrusted keys: its own
    # context's, and those of every workflow it is nested in.
    module StepIO
      INPUT_ROLES = %w[user assistant].freeze
      INHERITED_UNTRUSTED_KEYS = :smith_inherited_untrusted_keys
      private_constant :INPUT_ROLES, :INHERITED_UNTRUSTED_KEYS

      # Builds a nested workflow with its parent's untrusted keys in force
      # from construction, before its seed builder runs.
      def self.with_inherited_untrusted_keys(keys)
        outer = Thread.current[INHERITED_UNTRUSTED_KEYS]
        Thread.current[INHERITED_UNTRUSTED_KEYS] = untrusted_key_names!(keys)
        yield
      ensure
        Thread.current[INHERITED_UNTRUSTED_KEYS] = outer
      end

      # Context key names: at most 1,000, each a Symbol or String of 1 to 256
      # characters, as Symbols.
      def self.untrusted_key_names!(keys)
        valid = keys.is_a?(Array) && keys.length <= 1_000 &&
                keys.all? { (_1.is_a?(Symbol) || _1.is_a?(String)) && _1.length.between?(1, 256) }
        raise WorkflowError, "untrusted keys must be up to 1,000 context key names" unless valid

        keys.map(&:to_sym).uniq.freeze
      end

      # The keys handed to the workflow under construction; taken once, so a
      # workflow its constructor builds does not inherit them too.
      def self.take_inherited_untrusted_keys
        keys = Thread.current[INHERITED_UNTRUSTED_KEYS]
        Thread.current[INHERITED_UNTRUSTED_KEYS] = nil
        keys || [].freeze
      end

      private

      def isolated_session? = self.class.session == :isolated

      def untrusted_context_keys
        manager = self.class.context_manager
        own = manager.respond_to?(:untrusted_keys) ? manager.untrusted_keys : []
        own | (@inherited_untrusted_keys || [])
      end

      # The context without its untrusted keys, as `inject_state` formatters
      # and the `seed_messages` builder read it.
      def trusted_context_view
        keys = untrusted_context_keys
        keys.empty? || !@context.is_a?(Hash) ? @context : @context.except(*keys)
      end

      # The messages an agent step sees: its `input:`, or else the session
      # transcript (with injected state). An isolated session has no
      # transcript to give: an agent step there must declare `input:`, and
      # any other step gets nothing, so state is never injected.
      def step_prepared_input(transition)
        return step_input_messages(transition) if transition.step_input
        return build_session&.prepare! unless isolated_session?
        return unless transition.agent_step?

        raise WorkflowError, "transition #{DiagnosticText.capture(transition.name.to_s, max_bytes: 256)} runs an " \
                             "agent in an isolated session and must declare input:"
      end

      # A non-empty Array of at most MessageBatch::MAX_MESSAGES user and
      # assistant messages, bounded and JSON-shaped like session messages.
      # The callable gets a copy of the context, so it cannot change the
      # run's.
      def step_input_messages(transition)
        messages = transition.step_input.call(snapshot_value(@context))
        unless messages.is_a?(Array) && !messages.empty? && messages.length <= MessageBatch::MAX_MESSAGES
          raise WorkflowError, "input: must return a non-empty Array of at most #{MessageBatch::MAX_MESSAGES} messages"
        end

        MessageValueNormalizer.new(messages, label: "step input").call.map { |message| step_input_message(message) }
      end

      def step_input_message(message)
        unless message.is_a?(Hash) && message.keys.sort == %w[content role] && INPUT_ROLES.include?(message["role"]) &&
               !message["content"].nil?
          raise WorkflowError, "each input: message must be { role: :user or :assistant, content: } with content"
        end

        { role: message["role"].to_sym, content: message["content"] }
      end

      # Checked before the step runs, so a key the persist list refuses
      # costs no agent call.
      def writable_output_key!(transition)
        key = transition.output_to
        keys = declared_persist_keys
        raise UndeclaredContextKey.new(key:, persisted_keys: keys) if keys && !keys.include?(key)

        key
      end

      # The step's output, nil included, under `output_to:`: JSON-shaped and
      # in the context's key shape, so it reads the same live and restored.
      def deliver_output_to(transition, output)
        key = writable_output_key!(transition)
        value = MessageValueNormalizer.new(output, label: "output_to: value",
                                                   max_bytes: ExecutionResultSnapshot::MAX_BYTES).call
        @context[key] = ContextKeys.normalize(value)
        record_persisted_key!(key)
      end

      def transcript_output?(transition) = transition.output_to.nil? && !isolated_session?
    end
  end
end
