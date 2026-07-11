# frozen_string_literal: true

require "json"

module Smith
  class Workflow
    module Durability
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def restore(key, adapter: Smith.persistence_adapter)
          resolved_key = explicit_persistence_key!(key)
          payload = fetch_persisted_payload(resolved_key, adapter:)
          return nil unless payload

          from_state(JSON.parse(payload)).tap do |workflow|
            workflow.instance_variable_set(:@persistence_key, resolved_key)
          end
        end

        def restore_or_initialize(key: nil, context: {}, adapter: Smith.persistence_adapter, **kwargs)
          restore(resolved_persistence_key(key:, context:), adapter:) || new(context:, **kwargs)
        end

        # Peek without instantiating: returns true if persisted state
        # exists for the resolved key, false otherwise. Reuses the
        # existing private helpers (`resolved_persistence_key`,
        # `fetch_persisted_payload`) so it doesn't expand the adapter
        # contract — `Smith::PersistenceAdapter` requires only
        # `store/fetch/delete`, and this peek piggybacks on `fetch`.
        # Custom adapters work without changes.
        #
        # Hosts can use this to distinguish a resumed workflow from a
        # brand-new workflow when coordinating external accounting or
        # admission-control checks.
        def persisted_state_exists?(key: nil, context: {}, adapter: Smith.persistence_adapter)
          resolved_key = resolved_persistence_key(key:, context:)
          !fetch_persisted_payload(resolved_key, adapter:).nil?
        end

        # Stricter peek: returns true only when persisted state contains
        # billable work that needs to be preserved (at least one
        # `usage_entries` entry).
        #
        # `persisted_state_exists?` answers "is there any state?" — but
        # that includes the bare initial-state record Smith writes at
        # the top of `run_persisted!` BEFORE the first `advance!`. A
        # worker that dies between that initial `persist!` and the
        # first model call leaves a Redis key with no billable work.
        # If external accounting or admission-control checks key on
        # `persisted_state_exists?` alone, a retry on that abandoned
        # init state can be mistaken for a billable/resumable workflow.
        #
        # `restorable_billing_state?` returns true only when there's
        # actual `usage_entries` to bill on idempotent replay. Terminal
        # state with zero entries is also `false` because there's
        # nothing to preserve — `run_persisted!` is a no-op on
        # terminal anyway, so guard outcome doesn't matter for
        # correctness in that case.
        #
        # This calls `restore` (full deserialize) rather than just
        # `fetch`, so it's heavier than `persisted_state_exists?`. Use
        # this when you specifically want the billing-aware semantics;
        # use `persisted_state_exists?` when you only need a key-
        # presence check.
        def restorable_billing_state?(key: nil, context: {}, adapter: Smith.persistence_adapter)
          resolved_key = resolved_persistence_key(key:, context:)
          payload = fetch_persisted_payload(resolved_key, adapter:)
          return false if payload.nil?

          workflow = from_state(JSON.parse(payload))
          entries = workflow.instance_variable_get(:@usage_entries) || []
          entries.any?
        end

        def stuck_for?(persistence_key:, threshold:, since: nil, adapter: Smith.persistence_adapter)
          raise WorkflowError, "persistence_adapter is not configured" if adapter.nil?
          raise ArgumentError, "persistence_key must not be blank" if persistence_key.nil? || (persistence_key.respond_to?(:strip) && persistence_key.strip.empty?)
          raise ArgumentError, "threshold must respond to :to_i" unless threshold.respond_to?(:to_i)

          if since && !since.respond_to?(:to_time)
            raise ArgumentError, "since must respond to :to_time or be nil"
          end

          threshold_seconds = threshold.to_i
          now = Time.now.utc

          if Smith::PersistenceAdapters.supports?(adapter, :last_heartbeat)
            hb = adapter.last_heartbeat(persistence_key)
            if hb
              age = (now - hb.to_time.utc).to_f
              return false if age < threshold_seconds
            end
          end

          payload = adapter.fetch(persistence_key)
          return stuck_for_no_payload?(since, now, threshold_seconds) if payload.nil?

          if !Smith::PersistenceAdapters.supports?(adapter, :last_heartbeat)
            Smith::PersistenceAdapters.warn_missing_heartbeat(adapter)
            fallback_age = age_from_payload_updated_at(payload, now)
            return false if fallback_age.nil? || fallback_age < threshold_seconds
          end

          !terminal_in_payload?(payload)
        end

        def heartbeat_age(persistence_key:, adapter: Smith.persistence_adapter)
          raise WorkflowError, "persistence_adapter is not configured" if adapter.nil?

          if Smith::PersistenceAdapters.supports?(adapter, :last_heartbeat)
            hb = adapter.last_heartbeat(persistence_key)
            return [Time.now.utc - hb.to_time.utc, 0.0].max.to_f if hb
          end

          payload = adapter.fetch(persistence_key)
          return nil if payload.nil?

          age_from_payload_updated_at(payload, Time.now.utc)
        end

        def run_persisted!(key: nil, context: {}, adapter: Smith.persistence_adapter, clear: :done, on_step: nil, **kwargs)
          clear_policy = normalize_clear_policy(clear)
          resolved_key = resolved_persistence_key(key:, context:)
          workflow = restore(resolved_key, adapter:) || new(context:, **kwargs)
          result = workflow.run_persisted!(resolved_key, adapter:, on_step:)

          workflow.clear_persisted!(resolved_key, adapter:) if clear_persisted_after_run?(clear_policy, workflow)
          result
        end

        private

        def fetch_persisted_payload(key, adapter:)
          persistence_adapter!(adapter).fetch(key)
        end

        def stuck_for_no_payload?(since, now, threshold_seconds)
          return false if since.nil?

          age = (now - since.to_time.utc).to_f
          age.clamp(0.0, Float::INFINITY) >= threshold_seconds
        end

        def age_from_payload_updated_at(payload, now)
          parsed = JSON.parse(payload)
          updated_at = parsed["updated_at"] || parsed[:updated_at]
          return nil if updated_at.nil?

          (now - Time.parse(updated_at.to_s).utc).to_f
        rescue JSON::ParserError, ArgumentError
          nil
        end

        def terminal_in_payload?(payload)
          parsed = JSON.parse(payload)
          state_name = parsed["state"] || parsed[:state]
          class_name = parsed["class"] || parsed[:class]
          next_transition = parsed["next_transition_name"] || parsed[:next_transition_name]

          return false unless state_name && class_name

          klass = Object.const_get(class_name)
          state = state_name_for_payload(klass, state_name)
          klass.transitions_from(state).empty? && next_transition.nil?
        rescue JSON::ParserError, NameError, NoMethodError
          false
        end

        def state_name_for_payload(klass, state_name)
          states = klass.instance_variable_get(:@states) || []
          return state_name if states.include?(state_name)

          symbolized = state_name.to_sym if state_name.respond_to?(:to_sym)
          return symbolized if states.include?(symbolized)

          state_name
        end

        def persistence_adapter!(adapter)
          return adapter if adapter

          raise WorkflowError, "persistence_adapter is not configured"
        end

        def resolve_persistence_key!(key:, context:)
          return key unless key.nil? || blank_key?(key)

          builder = persistence_key
          raise WorkflowError, "persistence key is required unless workflow defines persistence_key" unless builder

          derived = if builder.arity == 1
            builder.call(context)
          else
            builder.call
          end

          return derived unless blank_key?(derived)

          raise WorkflowError, "persistence_key must return a non-blank key"
        end

        def resolved_persistence_key(key:, context:)
          resolve_persistence_key!(key:, context:)
        end

        def explicit_persistence_key!(key)
          return key unless blank_key?(key)

          raise WorkflowError, "restore requires a non-blank explicit persistence key"
        end

        def blank_key?(value)
          return true if value.nil?
          return true if value.respond_to?(:strip) && value.strip.empty?

          value.respond_to?(:empty?) ? value.empty? : false
        end

        def normalize_clear_policy(clear)
          case clear
          when false, nil
            false
          when true, :done
            :done
          when :terminal
            :terminal
          else
            raise WorkflowError, "invalid clear policy #{clear.inspect}; expected false, :done, or :terminal"
          end
        end

        def clear_persisted_after_run?(clear_policy, workflow)
          return false if clear_policy == false
          return workflow.done? if clear_policy == :done

          workflow.terminal?
        end
      end

      def run_persisted!(key = nil, adapter: Smith.persistence_adapter, on_step: nil)
        return build_run_result([]) if terminal?

        resolved_key = resolve_persistence_key!(key)
        steps = []
        persist!(resolved_key, adapter:)

        until terminal?
          ensure_transition_budget!

          if strict_idempotency?
            mark_step_in_progress!
            persist!(resolved_key, adapter:)
          end

          begin
            step = advance!
          rescue StandardError
            clear_pre_step_marker!(resolved_key, adapter:)
            raise
          end
          steps << step if step

          clear_step_in_progress!
          persist!(resolved_key, adapter:)
          invoke_on_step_callback(step, on_step) if step
        end

        build_run_result(steps)
      end

      def advance_persisted!(key = nil, adapter: Smith.persistence_adapter, on_step: nil)
        return if terminal?

        resolved_key = resolve_persistence_key!(key)
        ensure_transition_budget!
        mark_step_in_progress! if strict_idempotency?
        persist!(resolved_key, adapter:)
        step = advance!
        clear_step_in_progress!
        persist!(resolved_key, adapter:) if step
        invoke_on_step_callback(step, on_step) if step
        step
      rescue StandardError
        clear_pre_step_marker!(resolved_key, adapter:) if defined?(resolved_key) && resolved_key
        raise
      end

      def persist!(key = nil, adapter: Smith.persistence_adapter)
        resolved_key = resolve_persistence_key!(key)
        store = persistence_adapter!(adapter)
        previous_version = @persistence_version || 0
        next_version = previous_version + 1
        payload = JSON.generate(to_state.merge(persistence_version: next_version))
        payload = yield(payload, next_version) if block_given?

        dispatch_store!(store, resolved_key, payload, previous_version: previous_version)

        # Increment ONLY after successful store. On PersistenceVersionConflict
        # (raised by store_versioned), @persistence_version stays at the
        # previous value so callers can rescue + restore + retry cleanly.
        @persistence_version = next_version
        self
      end

      def clear_persisted!(key = nil, adapter: Smith.persistence_adapter)
        resolved_key = resolve_persistence_key!(key)
        persistence_adapter!(adapter).delete(resolved_key)
        self
      end

      def mark_step_in_progress!
        @step_in_progress = true
      end

      def clear_step_in_progress!
        @step_in_progress = false
      end

      private

      def strict_idempotency?
        self.class.idempotency_mode == :strict
      end

      def clear_pre_step_marker!(key, adapter:)
        return unless strict_idempotency?
        return if step_work_started?

        clear_step_in_progress!
        persist!(key, adapter:)
      end

      # Forwards the persist payload to the adapter, splatting `ttl:`
      # only when a TTL is resolved. The empty-Hash splat is a no-op so
      # external duck-typed adapters that don't accept a `ttl:` kwarg
      # keep working; they only break if the host opts into TTL.
      def dispatch_store!(store, key, payload, previous_version:)
        kwargs = ttl_kwarg(effective_persistence_ttl)

        if Smith::PersistenceAdapters.supports?(store, :store_versioned)
          store.store_versioned(key, payload, expected_version: previous_version, **kwargs)
        else
          Smith::PersistenceAdapters.warn_missing_versioning(store)
          store.store(key, payload, **kwargs)
        end

        store.record_heartbeat(key, **kwargs) if Smith::PersistenceAdapters.supports?(store, :record_heartbeat)
      end

      # Resolves the effective TTL once per persist, with the class-level
      # DSL override taking precedence over Smith.config.persistence_ttl.
      # Returns nil when neither is set, which collapses ttl_kwarg to an
      # empty Hash and preserves the pre-TTL adapter call shape.
      def effective_persistence_ttl
        self.class.persistence_ttl || Smith.config.persistence_ttl
      end

      def ttl_kwarg(ttl)
        ttl ? { ttl: ttl } : {}
      end

      def persistence_adapter!(adapter)
        return adapter if adapter

        raise WorkflowError, "persistence_adapter is not configured"
      end

      def resolve_persistence_key!(key)
        unless key.nil? || blank_key?(key)
          @persistence_key = key
          return key
        end

        return @persistence_key unless blank_key?(@persistence_key)

        @persistence_key = self.class.send(:resolve_persistence_key!, key:, context: @context)
      end

      def blank_key?(value)
        return true if value.nil?
        return true if value.respond_to?(:strip) && value.strip.empty?

        value.respond_to?(:empty?) ? value.empty? : false
      end

      def invoke_on_step_callback(step, callback)
        callback&.call(step)
      rescue StandardError => e
        Smith.config.logger&.error("Smith::Workflow on_step callback error: #{e.message}")
      end
    end
  end
end
