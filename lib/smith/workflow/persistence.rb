# frozen_string_literal: true

module Smith
  class Workflow
    module Persistence
      def to_state
        {
          class: self.class.name,
          state: @state,
          context: persisted_context,
          budget_consumed: ledger_consumed,
          step_count: @step_count,
          execution_namespace: @execution_namespace,
          created_at: @created_at,
          updated_at: @updated_at
        }
      end

      private

      def restore_state(hash)
        @state = hash[:state]
        @context = filter_persisted_context(hash[:context] || {})
        @step_count = hash[:step_count] || 0
        @execution_namespace = hash[:execution_namespace]
        @created_at = hash[:created_at]
        @updated_at = hash[:updated_at]
        @ledger = rebuild_ledger(hash[:budget_consumed] || {})
      end

      def ledger_consumed
        @ledger ? @ledger.consumed.to_h : {}
      end

      def rebuild_ledger(consumed)
        config = self.class.budget
        return nil unless config

        Budget::Ledger.new(limits: config, consumed: consumed)
      end

      def persisted_context
        keys = resolve_persist_keys
        keys ? @context.slice(*keys) : @context
      end

      def filter_persisted_context(context)
        keys = resolve_persist_keys
        keys ? context.slice(*keys) : context
      end

      def resolve_persist_keys
        manager = self.class.context_manager
        return nil unless manager

        keys = manager.persist
        keys.empty? ? nil : keys
      end
    end
  end
end
