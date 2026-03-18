# frozen_string_literal: true

module Smith
  class Context
    class Session
      attr_reader :messages

      def initialize(messages:, context_manager:, persisted_context:)
        @messages = messages
        @context_manager = context_manager
        @persisted_context = persisted_context
      end

      def inject_state!
        formatter = @context_manager.inject_state
        return unless formatter

        @messages.replace(
          StateInjection.inject(@messages, formatter: formatter, persisted: @persisted_context)
        )
      end

      def masked_view
        strategy = @context_manager.session_strategy
        ObservationMasking.apply(@messages, strategy: strategy)
      end

      def append(message)
        @messages << message
      end
    end
  end
end
