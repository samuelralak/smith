# frozen_string_literal: true

module Smith
  class Workflow
    module Persistence
      def to_state
        {
          class: self.class.name,
          state: @state,
          persistence_key: @persistence_key,
          context: persisted_context,
          budget_consumed: ledger_consumed,
          step_count: @step_count,
          execution_namespace: @execution_namespace,
          created_at: @created_at,
          updated_at: @updated_at,
          next_transition_name: @next_transition_name,
          session_messages: @session_messages || [],
          total_cost: @total_cost || 0.0,
          total_tokens: @total_tokens || 0,
          tool_results: @tool_results || [],
          outcome: snapshot_outcome
        }
      end

      private

      def restore_state(hash)
        normalized = normalize_persisted_state(hash)
        restore_core_fields(normalized)
        @persistence_key = normalized[:persistence_key]
        @ledger = rebuild_ledger(normalized[:budget_consumed] || {})
        @next_transition_name = normalized[:next_transition_name]
        @session_messages = normalized[:session_messages] || []
        @total_cost = normalized[:total_cost] || 0.0
        @total_tokens = normalized[:total_tokens] || 0
        @outcome = normalized[:outcome]
        initialize_tool_result_state
        @tool_results = normalized[:tool_results] || []
      end

      def restore_core_fields(normalized)
        @state = normalized[:state]
        @context = filter_persisted_context(normalized[:context] || {})
        @step_count = normalized[:step_count] || 0
        @execution_namespace = normalized[:execution_namespace]
        @created_at = normalized[:created_at]
        @updated_at = normalized[:updated_at]
      end

      def normalize_persisted_state(hash)
        normalized = hash.transform_keys { |k| k.is_a?(String) ? k.to_sym : k }
        normalize_symbol_fields!(normalized)
        normalize_nested_hashes!(normalized)
        normalize_session_messages!(normalized)
        normalize_tool_results!(normalized)
        normalized[:outcome] = symbolize_value(normalized[:outcome]) if normalized[:outcome].is_a?(Hash)
        normalized
      end

      def normalize_symbol_fields!(normalized)
        normalized[:state] = normalized[:state]&.to_sym
        if normalized[:outcome].is_a?(Hash) && normalized[:outcome].key?(:kind)
          normalized[:outcome][:kind] = normalized[:outcome][:kind]&.to_sym
        elsif normalized[:outcome].is_a?(Hash) && normalized[:outcome].key?("kind")
          normalized[:outcome]["kind"] = normalized[:outcome]["kind"]&.to_sym
        end
        return unless normalized.key?(:next_transition_name)

        normalized[:next_transition_name] = normalized[:next_transition_name]&.to_sym
      end

      def normalize_nested_hashes!(normalized)
        normalized[:context] = symbolize_keys(normalized[:context]) if normalized[:context].is_a?(Hash)
        return unless normalized[:budget_consumed].is_a?(Hash)

        normalized[:budget_consumed] = symbolize_keys(normalized[:budget_consumed])
      end

      def normalize_session_messages!(normalized)
        return unless normalized[:session_messages].is_a?(Array)

        normalized[:session_messages] = normalized[:session_messages].map do |msg|
          msg.is_a?(Hash) ? symbolize_keys(msg) : msg
        end
      end

      def normalize_tool_results!(normalized)
        return unless normalized[:tool_results].is_a?(Array)

        normalized[:tool_results] = normalized[:tool_results].map do |entry|
          entry.is_a?(Hash) ? symbolize_keys(entry) : entry
        end
      end

      def symbolize_keys(hash)
        hash.transform_keys { |k| k.is_a?(String) ? k.to_sym : k }
      end

      def symbolize_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested), copy|
            normalized_key = key.is_a?(String) ? key.to_sym : key
            copy[normalized_key] = symbolize_value(nested)
          end
        when Array
          value.map { |nested| symbolize_value(nested) }
        else
          value
        end
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
