# frozen_string_literal: true

module Smith
  module Events
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
