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

    REGISTRY_MUTEX = Mutex.new
    private_constant :REGISTRY_MUTEX

    class << self
      # Registration-ordered snapshot of the live subscriptions. Cancelled
      # subscriptions are detached from the registry, so this reflects only
      # what will actually receive events.
      def subscriptions
        snapshot = REGISTRY_MUTEX.synchronize { registry.values.flatten }
        snapshot.sort_by!(&:sequence_number)
      end

      def on(event_class, **opts, &block)
        sub = Subscription.new(event_class, handler: block, predicate: opts[:if])
        REGISTRY_MUTEX.synchronize do
          @sequence = (@sequence || 0) + 1
          sub.sequence_number = @sequence
          (registry[event_class] ||= []) << sub
        end
        sub
      end

      # Removes a subscription from the registry. Called by
      # Subscription#cancel; safe to call more than once.
      def detach(subscription)
        REGISTRY_MUTEX.synchronize do
          bucket = registry[subscription.event_class]
          next unless bucket

          bucket.delete(subscription)
          registry.delete(subscription.event_class) if bucket.empty?
        end
        nil
      end

      def emit(event)
        matching_subscriptions(event).each { |sub| dispatch_to(sub, event) }
      end

      def within
        scope = Scope.new
        yield scope
      ensure
        scope&.cancel_all
      end

      def reset!
        REGISTRY_MUTEX.synchronize do
          @registry = {}
          @sequence = 0
        end
      end

      private

      def registry
        @registry ||= {}
      end

      # Subscriptions live in per-class buckets so one emit touches only the
      # buckets for the event's ancestors instead of scanning every
      # subscription; `is_a?` dispatch semantics are preserved exactly
      # because a subscription matches iff its registered class or module is
      # among the event class's ancestors. The merged candidates are ordered
      # by registration sequence, keeping subscription-order dispatch.
      # Handlers run outside the registry lock so a handler may subscribe or
      # cancel without deadlocking.
      def matching_subscriptions(event)
        # singleton_class.ancestors, not class.ancestors: it additionally
        # covers modules mixed into the event instance via extend, which
        # `is_a?` matched before the bucketed registry existed. Immediates
        # (Integer, Symbol, Float) have no singleton class; they also cannot
        # be extended, so their class ancestors are the complete `is_a?` set.
        ancestors = begin
          event.singleton_class.ancestors
        rescue TypeError
          event.class.ancestors
        end
        candidates = REGISTRY_MUTEX.synchronize do
          ancestors.each_with_object([]) do |ancestor, found|
            bucket = registry[ancestor]
            found.concat(bucket) if bucket
          end
        end
        candidates.sort_by!(&:sequence_number)
      end

      def dispatch_to(sub, event)
        return if sub.cancelled?
        return if sub.predicate && !sub.predicate.call(event)

        sub.handler.call(event)
      rescue StandardError => e
        Smith.config.logger&.error("Smith::Events handler error: #{e.message}")
      end
    end
  end
end
