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
