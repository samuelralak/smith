# frozen_string_literal: true

module Smith
  module Events
    class Subscription
      attr_reader :event_class, :handler, :predicate

      def initialize(event_class, handler:, predicate: nil)
        @event_class = event_class
        @handler = handler
        @predicate = predicate
        @cancelled = false
      end

      def cancel
        @cancelled = true
      end

      def cancelled?
        @cancelled
      end
    end
  end
end
