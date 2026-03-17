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

    class Scope
      def initialize
        @handles = []
      end

      def on(event_class, **, &)
        handle = Events.on(event_class, **, &)
        @handles << handle
        handle
      end

      def cancel_all
        @handles.each(&:cancel)
      end
    end

    class << self
      def subscriptions
        @subscriptions ||= []
      end

      def on(event_class, **opts, &block)
        sub = Subscription.new(event_class, handler: block, predicate: opts[:if])
        subscriptions << sub
        sub
      end

      def within
        scope = Scope.new
        yield scope
      ensure
        scope&.cancel_all
      end

      def reset!
        @subscriptions = []
      end
    end
  end
end
