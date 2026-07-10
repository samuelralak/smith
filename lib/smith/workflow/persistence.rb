# frozen_string_literal: true

require_relative "usage_entry"

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
          outcome: snapshot_outcome,
          # Durable usage fields. All wrapped in
          # snapshot_value so non-JSON-safe runtime values (e.g.
          # custom Hash details on DeterministicStepFailure) get the
          # same deep-copy treatment as context/session_messages/etc.
          usage_entries: snapshot_value((@usage_entries || []).map(&:to_h)),
          last_output: snapshot_value(@last_output),
          last_failed_step: snapshot_value(@last_failed_step),
          # Optimistic-locking version. Adapters that support
          # store_versioned use this to detect concurrent writes; adapters
          # that don't (CacheStore, RailsCache) ignore it.
          persistence_version: @persistence_version || 0,
          # Schema version of the workflow class that wrote this payload.
          # Restore dispatches through migrate_from blocks when the
          # stored value lags the workflow's current
          # persistence_schema_version.
          schema_version: self.class.persistence_schema_version,
          # SHA256 digest of the seed_messages produced at this
          # workflow's construction. Stays stable across persist/restore
          # cycles so seed_validation can detect when the seed builder
          # has changed in code since this workflow was persisted.
          seed_digest: @seed_digest,
          # Step-in-progress idempotency marker. Set true between
          # persist-before-advance and persist-after-advance when the
          # workflow class opts into idempotency_mode :strict. Restore
          # raises Smith::StepInProgressOnRestore if true under strict
          # mode. Lax mode leaves this false and never raises.
          step_in_progress: @step_in_progress || false,
          # Keys recorded via DeterministicStep#write_context. Used by
          # persist :auto Context mode to scope the persisted context
          # slice. Always emitted (sorted for stable diffing) so
          # explicit-mode workflows produce forward-compatible payloads.
          persisted_keys: (@persisted_keys || ::Set.new).to_a.map(&:to_sym).sort
        }
      end

      private

      def restore_state(hash)
        migrated = migrate_if_needed(hash)
        normalized = normalize_persisted_state(migrated)
        persistence_version = validated_persistence_version(normalized)
        restore_persisted_keys(normalized)
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
        # Mirror the eager inits from `Workflow#initialize`. `from_state`
        # uses `allocate` and bypasses `initialize`, so any restored
        # workflow that later records usage would `nil.synchronize` or
        # `nil.map` without these. Backward-compat: pre-patch states
        # have no `usage_entries`/`last_output`/`last_failed_step` keys
        # and restore to the empty defaults.
        @usage_mutex = Mutex.new
        @usage_entries = restore_usage_entries(normalized)
        @last_output = restore_last_output(normalized)
        @last_failed_step = restore_last_failed_step(normalized)
        # Restore the optimistic-locking version from the persisted payload.
        # Backward-compat: pre-versioning payloads have no key, restore to 0
        # so the first persist! after restore expects version 0 (matches
        # the original store from the legacy adapter contract).
        @persistence_version = persistence_version
        # Preserve the seed digest from the persisted payload so it
        # round-trips on subsequent persists. validate_seed_digest!
        # compares this against a fresh evaluation of the seed builder
        # only when the workflow class opts into validation.
        @seed_digest = normalized[:seed_digest]
        validate_seed_digest!(normalized) if self.class.seed_validation != :off
        # Restore the step-in-progress marker so a subsequent persist
        # round-trips it. validate_step_in_progress! enforces strict
        # mode by raising if the marker is set on restore.
        @step_in_progress = normalized[:step_in_progress] || false
        validate_step_in_progress!(normalized) if self.class.idempotency_mode == :strict
      end

      def validated_persistence_version(normalized)
        version = normalized.fetch(:persistence_version, 0)
        return version if version.is_a?(Integer) && version >= 0

        raise Smith::SerializationError,
              "persisted workflow persistence_version must be a non-negative integer, got #{version.inspect}"
      end

      def validate_step_in_progress!(normalized)
        return unless normalized[:step_in_progress] == true

        raise Smith::StepInProgressOnRestore.new(
          workflow: self.class.name,
          persistence_key: normalized[:persistence_key]
        )
      end

      def validate_seed_digest!(normalized)
        stored_digest = normalized[:seed_digest]
        return if stored_digest.nil?

        current_messages = compute_seed_messages
        current_digest = compute_seed_digest(current_messages)
        return if current_digest == stored_digest

        case self.class.seed_validation
        when :strict
          raise Smith::SeedMismatch.new(
            workflow: self.class.name,
            stored_digest: stored_digest,
            current_digest: current_digest
          )
        when :warn
          Smith.config.logger&.warn(
            "Smith::Workflow seed_messages drift for #{self.class.name}: " \
            "stored digest #{stored_digest.inspect}, current digest #{current_digest.inspect}"
          )
        end
      end

      def restore_usage_entries(normalized)
        raw = normalized[:usage_entries]
        return [] if raw.nil? || !raw.is_a?(Array)

        raw.map { |h| Workflow::UsageEntry.from_h(h) }
      end

      # Use key-presence checks (NOT `||`) so a deliberately persisted
      # `false` step output round-trips correctly. Smith's existing
      # `RunResult#output` derivation uses `compact.first`, which only
      # drops `nil` — `false` is a valid non-nil output.
      def restore_last_output(normalized)
        if normalized.key?(:last_output)
          normalized[:last_output]
        elsif normalized.key?("last_output")
          normalized["last_output"]
        end
      end

      # Symbolize ONLY the top-level keys of last_failed_step + the
      # known value-symbols (`transition`, `from`, `to`, `error_kind`).
      # `error_family` stays a String (the family_fallback compares
      # against String literals). `error_details` is left exactly as
      # JSON.parse returned it — documented as JSON-normalized
      # semantics on round-trip (Hash keys become strings, symbol
      # values become strings).
      def restore_last_failed_step(normalized)
        raw = normalized[:last_failed_step]
        return nil unless raw.is_a?(Hash)

        h = raw.transform_keys { |k| k.is_a?(String) ? k.to_sym : k }
        {
          transition: normalize_transition_name(h[:transition]),
          from: normalize_state_name(h[:from]),
          to: normalize_state_name(h[:to]),
          error_class: h[:error_class],
          error_family: h[:error_family],
          error_message: h[:error_message],
          error_retryable: h[:error_retryable],
          error_kind: h[:error_kind]&.to_sym,
          error_details: h[:error_details]
        }
      end

      def restore_core_fields(normalized)
        @state = normalized[:state]
        @context = filter_persisted_context(normalized[:context] || {})
        @step_count = normalized[:step_count] || 0
        @execution_namespace = normalized[:execution_namespace]
        @created_at = normalized[:created_at]
        @updated_at = normalized[:updated_at]
      end

      def restore_persisted_keys(normalized)
        @persisted_keys_mutex = Mutex.new
        raw = normalized[:persisted_keys]
        if raw.is_a?(Array) && !raw.empty?
          @persisted_keys = ::Set.new(raw.map(&:to_sym))
          return
        end

        manager = self.class.context_manager
        if manager && manager.respond_to?(:persist_mode) && manager.persist_mode == :auto
          ctx = normalized[:context]
          existing = ctx.is_a?(Hash) ? ctx.keys.map { |k| k.to_sym } : []
          seed = manager.persist_auto_seed.map(&:to_sym)
          @persisted_keys = ::Set.new(existing + seed)
        else
          @persisted_keys = ::Set.new
        end
      end

      # Bridges stored schema_version to the workflow class's current
      # persistence_schema_version by walking registered migrate_from
      # blocks one step at a time. Returns the (possibly migrated)
      # payload with symbol top-level keys, ready for the rest of the
      # normalize pipeline. Pre-versioning payloads are treated as v1
      # for backward compatibility with state written before Smith
      # carried :schema_version.
      def migrate_if_needed(hash)
        payload = hash.transform_keys { |k| k.is_a?(String) ? k.to_sym : k }
        current = self.class.persistence_schema_version
        stored = payload[:schema_version] || 1

        return payload if stored == current

        if stored > current
          raise Smith::PersistenceSchemaMismatch.new(
            workflow: self.class.name, stored: stored, current: current
          )
        end

        cursor = stored
        while cursor < current
          migration = self.class.migrations[cursor]
          unless migration
            raise Smith::PersistenceSchemaMismatch.new(
              workflow: self.class.name, stored: cursor, current: current
            )
          end

          payload = migration.call(payload)
          payload = payload.transform_keys { |k| k.is_a?(String) ? k.to_sym : k }
          cursor += 1
          # Defensive: advance :schema_version if the migration block
          # forgot to set it, so the loop terminates.
          payload[:schema_version] = cursor if (payload[:schema_version] || 0) < cursor
        end

        payload
      end

      def normalize_persisted_state(hash)
        normalized = hash.transform_keys { |k| k.is_a?(String) ? k.to_sym : k }
        normalize_symbol_fields!(normalized)
        normalize_nested_hashes!(normalized)
        normalize_session_messages!(normalized)
        normalize_tool_results!(normalized)
        normalize_usage_entries!(normalized)
        normalized[:outcome] = symbolize_value(normalized[:outcome]) if normalized[:outcome].is_a?(Hash)
        normalized
      end

      def normalize_symbol_fields!(normalized)
        normalized[:state] = normalize_state_name(normalized[:state])
        if normalized[:outcome].is_a?(Hash) && normalized[:outcome].key?(:kind)
          normalized[:outcome][:kind] = normalized[:outcome][:kind]&.to_sym
        elsif normalized[:outcome].is_a?(Hash) && normalized[:outcome].key?("kind")
          normalized[:outcome]["kind"] = normalized[:outcome]["kind"]&.to_sym
        end
        return unless normalized.key?(:next_transition_name)

        normalized[:next_transition_name] = normalize_transition_name(normalized[:next_transition_name])
      end

      def normalize_transition_name(value)
        return if value.nil?
        transition = self.class.find_transition(value)
        return transition.name if transition
        return value unless value.is_a?(String)

        symbolized = value.to_sym
        transition = self.class.find_transition(symbolized)
        return transition.name if transition

        symbolized
      end

      def normalize_state_name(value)
        return if value.nil?
        return value if declared_state?(value)
        return value unless value.is_a?(String)

        symbolized = value.to_sym
        return symbolized if declared_state?(symbolized)

        symbolized
      end

      def declared_state?(value)
        states = self.class.instance_variable_get(:@states) || []
        states.include?(value)
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

      def normalize_usage_entries!(normalized)
        return unless normalized[:usage_entries].is_a?(Array)

        normalized[:usage_entries] = normalized[:usage_entries].map do |entry|
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
        return @context if keys.nil?
        return @context.slice(*(@persisted_keys || ::Set.new).to_a) if keys == :auto

        @context.slice(*keys)
      end

      def filter_persisted_context(context)
        keys = resolve_persist_keys
        return context if keys.nil?
        return context.slice(*(@persisted_keys || ::Set.new).to_a) if keys == :auto

        context.slice(*keys)
      end

      def resolve_persist_keys
        manager = self.class.context_manager
        return nil unless manager

        if manager.respond_to?(:persist_mode) && manager.persist_mode == :auto
          return :auto
        end

        keys = manager.persist
        keys.empty? ? nil : keys
      end
    end
  end
end
