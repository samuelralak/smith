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

      def emit(event)
        subscriptions.each { |sub| dispatch_to(sub, event) }
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

      private

      def dispatch_to(sub, event)
        return if sub.cancelled?
        return unless event.is_a?(sub.event_class)
        return if sub.predicate && !sub.predicate.call(event)

        sub.handler.call(event)
      rescue StandardError => e
        Smith.config.logger&.error("Smith::Events handler error: #{e.message}")
      end
    end
  end
end
