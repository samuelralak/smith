# frozen_string_literal: true

module Smith
  module Events
    class Subscription
      attr_reader :event_class, :handler, :predicate
      # Internal registration order, assigned by Events.on; dispatch and the
      # subscriptions snapshot sort by it.
      attr_accessor :sequence_number

      def initialize(event_class, handler:, predicate: nil)
        @event_class = event_class
        @handler = handler
        @predicate = predicate
        @cancelled = false
      end

      # Cancelling flags the subscription and detaches it from the registry
      # (so it cannot leak). The flag check against an in-flight emit
      # snapshot is best-effort: a dispatch already past the check may still
      # deliver once after cancel returns.
      def cancel
        @cancelled = true
        Events.detach(self)
      end

      def cancelled?
        @cancelled
      end
    end
  end
end
