# frozen_string_literal: true

module Smith
  class Workflow
    module DSL
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@states, (@states || []).dup)
          subclass.instance_variable_set(:@transitions, (@transitions || {}).dup)
          subclass.instance_variable_set(:@initial_state_name, @initial_state_name)
          subclass.instance_variable_set(:@budget_config, @budget_config&.dup)
          subclass.instance_variable_set(:@max_transitions_count, @max_transitions_count)
          subclass.instance_variable_set(:@guardrails_class, @guardrails_class)
          subclass.instance_variable_set(:@context_manager_class, @context_manager_class)
          subclass.instance_variable_set(:@seed_messages_builder, @seed_messages_builder)
          subclass.instance_variable_set(:@persistence_key_builder, @persistence_key_builder)
          subclass.instance_variable_set(:@persistence_schema_version, @persistence_schema_version)
          subclass.instance_variable_set(:@migrations, (@migrations || {}).dup)
          subclass.instance_variable_set(:@seed_validation_mode, @seed_validation_mode)
          subclass.instance_variable_set(:@idempotency_mode, @idempotency_mode)
          subclass.instance_variable_set(:@persistence_ttl, @persistence_ttl)
        end

        def initial_state(name = nil)
          return @initial_state_name if name.nil?

          @initial_state_name = name
          state(name)
        end

        def state(name)
          @states ||= []
          @states << name unless @states.include?(name)
          generate_fail_transition if name == :failed
        end

        def transition(name, from:, to:, &)
          @transitions ||= {}
          @transitions[name] = Transition.new(name, from: from, to: to, &)
        end

        def budget(**opts)
          return @budget_config if opts.empty?

          @budget_config = opts
        end

        def max_transitions(count = nil)
          return @max_transitions_count if count.nil?

          @max_transitions_count = count
        end

        def guardrails(klass = nil)
          return @guardrails_class if klass.nil?

          @guardrails_class = klass
        end

        def context_manager(klass = nil)
          return @context_manager_class if klass.nil?

          @context_manager_class = klass
        end

        def seed_messages(&block)
          return @seed_messages_builder unless block_given?

          @seed_messages_builder = block
        end

        def persistence_key(&block)
          return @persistence_key_builder unless block_given?

          @persistence_key_builder = block
        end

        # Schema version stamped into every persisted payload's
        # :schema_version key. Restore compares the stored version with
        # this value and either passes through (equal), applies
        # registered migrate_from blocks one step at a time (stored
        # less than current), or raises Smith::PersistenceSchemaMismatch
        # (stored greater than current, or unbridged gap).
        # Pre-versioning payloads (no :schema_version key) are treated
        # as v1 for backward compatibility.
        def persistence_schema_version(version = nil)
          return @persistence_schema_version || 1 if version.nil?

          unless version.is_a?(Integer) && version >= 1
            raise ArgumentError, "persistence_schema_version must be a positive Integer, got #{version.inspect}"
          end

          @persistence_schema_version = version
        end

        # Register a one-step migration from stored version N to N+1.
        # The block receives the persisted payload Hash (top-level keys
        # already symbolized) and must return the migrated payload.
        # Bumping the :schema_version key is the migration's
        # responsibility but Smith advances defensively if the block
        # omits it, so migrations stay loop-free.
        def migrate_from(version, &block)
          raise ArgumentError, "migrate_from requires a block" unless block

          unless version.is_a?(Integer) && version >= 1
            raise ArgumentError, "migrate_from version must be a positive Integer, got #{version.inspect}"
          end

          @migrations ||= {}
          @migrations[version] = block
        end

        def migrations
          @migrations || {}
        end

        # Controls whether restore validates that the seed_messages
        # builder still produces the same digest as when this workflow
        # was originally persisted.
        #
        # Modes:
        #   :off    (default) skip validation entirely. Recommended when
        #            the seed builder is non-deterministic (timestamps,
        #            UUIDs, request-scoped data) since drift would
        #            surface on every restore.
        #   :warn   log a warning via Smith.config.logger on drift; do
        #            not raise. Suitable for soft monitoring.
        #   :strict raise Smith::SeedMismatch on drift. Suitable when
        #            the seed builder is deterministic (system
        #            instructions, static templates) and divergence
        #            indicates a code change that would invalidate the
        #            persisted conversation context.
        def seed_validation(mode = nil)
          return @seed_validation_mode || :off if mode.nil?

          unless %i[strict warn off].include?(mode)
            raise ArgumentError, "seed_validation must be :strict, :warn, or :off, got #{mode.inspect}"
          end

          @seed_validation_mode = mode
        end

        # Controls whether run_persisted! / advance_persisted! stamp a
        # step_in_progress marker before each advance and clear it
        # afterward.
        #
        # Modes:
        #   :lax    (default) no marker stamping; restore never raises.
        #            Safe when agent calls and tools are idempotent, so
        #            re-running a step on restore is harmless.
        #   :strict marker is persisted before each advance and cleared
        #            after. Restore raises
        #            Smith::StepInProgressOnRestore when the marker is
        #            set, indicating a previous worker crashed mid-step
        #            and re-running could double-execute non-idempotent
        #            agent calls or tools.
        def idempotency_mode(mode = nil)
          return @idempotency_mode || :lax if mode.nil?

          unless %i[strict lax].include?(mode)
            raise ArgumentError, "idempotency_mode must be :strict or :lax, got #{mode.inspect}"
          end

          @idempotency_mode = mode
        end

        # Per-workflow TTL override (in seconds). Takes precedence over
        # Smith.config.persistence_ttl at persist! time. nil (default)
        # means inherit the global config.
        #
        # Hosts typically set this when different workflow classes have
        # different durability horizons: e.g., short-lived UI sessions
        # at 1.day.to_i, long-running research workflows at 30.days.to_i.
        #
        # Wiring contract: when the resolved TTL is non-nil,
        # Workflow#persist! forwards it to the adapter as a `ttl:`
        # kwarg. Shipped adapters (Memory, RedisStore, CacheStore,
        # ActiveRecordStore) accept this kwarg; external duck-typed
        # adapters that implement only the bare REQUIRED_METHODS contract
        # without a `ttl:` kwarg will only break when a host actually
        # opts into TTL.
        def persistence_ttl(seconds = nil)
          return @persistence_ttl if seconds.nil?

          unless seconds.is_a?(Numeric) && seconds.positive?
            raise ArgumentError,
                  "persistence_ttl must be a positive Numeric (seconds), got #{seconds.inspect}"
          end

          @persistence_ttl = seconds
        end

        def transitions_from(state)
          (@transitions || {}).values.select { |t| t.from == state }
        end

        def find_transition(name)
          (@transitions || {})[name]
        end

        def from_state(hash)
          workflow = allocate
          workflow.send(:restore_state, hash)
          workflow
        end

        private

        def generate_fail_transition
          @transitions ||= {}
          return if @transitions.key?(:fail)

          @transitions[:fail] = Transition.new(:fail, from: nil, to: :failed)
        end
      end
    end
  end
end
