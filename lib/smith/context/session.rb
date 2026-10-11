# frozen_string_literal: true

module Smith
  class Context
    class Session
      attr_reader :messages

      def initialize(messages:, context_manager:, persisted_context:, seed_message_count: 0, untrusted_keys: nil)
        @messages = messages
        @context_manager = context_manager
        @persisted_context = persisted_context
        @seed_message_count = seed_message_count
        @untrusted_keys = untrusted_keys
      end

      def inject_state!
        return unless @context_manager

        formatter = @context_manager.inject_state
        return unless formatter

        @messages.replace(
          StateInjection.inject(@messages, formatter: formatter, persisted: trusted_context)
        )
      end

      # The context without its untrusted keys: the run's own and those of
      # any workflow it is nested in, when the run passes them, or else its
      # context manager's.
      def trusted_context
        untrusted = @untrusted_keys
        untrusted ||= @context_manager.respond_to?(:untrusted_keys) ? @context_manager.untrusted_keys : []
        return @persisted_context if untrusted.empty? || !@persisted_context.is_a?(Hash)

        @persisted_context.except(*untrusted)
      end

      def masked_view
        return @messages unless @context_manager

        strategy = @context_manager.session_strategy
        ObservationMasking.apply(
          @messages,
          strategy: strategy,
          seed_message_count: @seed_message_count
        )
      end

      def prepare!
        inject_state!
        masked_view
      end

      def append(message)
        @messages << message
      end
    end
  end
end
