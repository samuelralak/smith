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
        # Hadithi uses this to skip the credits guard at execution time
        # when persisted state already exists for a workflow key (a
        # prior attempt's billable work is durable in Redis, OR an
        # in-flight workflow is being resumed — either way, no NEW
        # credit authorization is needed).
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
        # If the credits guard's bypass keys on `persisted_state_exists?`
        # alone, a zero-balance user's retry on that abandoned init
        # state silently runs the first model call (the guard is
        # skipped because state exists, but the state has nothing to
        # bill — it's just the workflow's starting state).
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
          step = advance!
          steps << step if step
          persist!(resolved_key, adapter:)
          invoke_on_step_callback(step, on_step) if step
        end

        build_run_result(steps)
      end

      def advance_persisted!(key = nil, adapter: Smith.persistence_adapter, on_step: nil)
        return if terminal?

        resolved_key = resolve_persistence_key!(key)
        persist!(resolved_key, adapter:)
        step = advance!
        persist!(resolved_key, adapter:) if step
        invoke_on_step_callback(step, on_step) if step
        step
      end

      def persist!(key = nil, adapter: Smith.persistence_adapter)
        resolved_key = resolve_persistence_key!(key)
        persistence_adapter!(adapter).store(resolved_key, JSON.generate(to_state))
        self
      end

      def clear_persisted!(key = nil, adapter: Smith.persistence_adapter)
        resolved_key = resolve_persistence_key!(key)
        persistence_adapter!(adapter).delete(resolved_key)
        self
      end

      private

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
