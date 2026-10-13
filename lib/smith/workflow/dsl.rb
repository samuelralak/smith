# frozen_string_literal: true

module Smith
  class Workflow
    module DSL
      BUDGET_KEYS = %i[total_tokens token_limit total_cost tool_calls wall_clock].freeze
      private_constant :BUDGET_KEYS

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@states, (@states || []).dup)
          subclass.instance_variable_set(:@transitions, (@transitions || {}).dup)
          subclass.instance_variable_set(
            :@transitions_by_state,
            duplicate_transition_index(@transitions_by_state)
          )
          subclass.instance_variable_set(:@transition_order, (@transition_order || {}).dup)
          subclass.instance_variable_set(:@generated_transitions, (@generated_transitions || []).dup)
          subclass.instance_variable_set(:@transition_sequence, @transition_sequence)
          subclass.instance_variable_set(:@initial_state_name, @initial_state_name)
          subclass.instance_variable_set(:@budget_config, @budget_config&.dup)
          subclass.instance_variable_set(:@budget_ledger_builder, @budget_ledger_builder)
          subclass.instance_variable_set(:@budget_ledger_scope_keys, @budget_ledger_scope_keys)
          subclass.instance_variable_set(:@max_transitions_count, @max_transitions_count)
          subclass.instance_variable_set(:@guardrails_class, @guardrails_class)
          subclass.instance_variable_set(:@context_manager_class, @context_manager_class)
          subclass.instance_variable_set(:@seed_messages_builder, @seed_messages_builder)
          subclass.instance_variable_set(:@persistence_key_builder, @persistence_key_builder)
          subclass.instance_variable_set(:@persistence_schema_version, @persistence_schema_version)
          subclass.instance_variable_set(:@migrations, (@migrations || {}).dup)
          subclass.instance_variable_set(:@renamed_states, @renamed_states)
          subclass.instance_variable_set(:@renamed_transitions, @renamed_transitions)
          subclass.instance_variable_set(:@seed_validation_mode, @seed_validation_mode)
          subclass.instance_variable_set(:@idempotency_mode, @idempotency_mode)
          subclass.instance_variable_set(:@session_mode, @session_mode)
          subclass.instance_variable_set(:@persistence_ttl, @persistence_ttl)
        end

        def initial_state(name = nil)
          return @initial_state_name if name.nil?

          @initial_state_name = own_identifier(name)
          state(@initial_state_name)
        end

        def state(name)
          name = own_identifier(name)
          @states ||= []
          @states << name unless @states.include?(name)
          generate_fail_transition if name == :failed
        end

        def transition(name, from:, to:, &)
          declared = Transition.new(name, from: from, to: to, &)
          name = declared.name
          @transitions ||= {}

          if @transitions.key?(name)
            remove_from_transition_index(@transitions[name])
            release_generated_transition_order(name)
          end

          @transitions[name] = declared
          insert_into_transition_index(declared)
        end

        def budget(**opts)
          return @budget_config if opts.empty?

          unknown = opts.keys - BUDGET_KEYS
          unless unknown.empty?
            raise ArgumentError, "workflow budget does not accept #{unknown.map(&:inspect).join(", ")}; " \
                                 "accepted keys are #{BUDGET_KEYS.map(&:inspect).join(", ")}"
          end

          @budget_config = opts
        end

        # The host's budget ledger for a run (Budget::HostLedger): the block
        # gets the run's scope, the values `scope_keys` have in its trusted
        # context when it is created, kept with the run, and returns the
        # ledger, or nil for none. It is built at the first request a step
        # makes, never persisted. Each provider request a step makes is held
        # on it first.
        def budget_ledger(*scope_keys, &block)
          return @budget_ledger_builder if scope_keys.empty? && !block
          raise ArgumentError, "budget_ledger needs a block that returns the ledger" unless block
          raise ArgumentError, "budget_ledger scope keys must be Symbols" unless scope_keys.all?(Symbol)

          @budget_ledger_scope_keys = scope_keys.uniq.freeze
          @budget_ledger_builder = block
        end

        def budget_ledger_scope_keys = @budget_ledger_scope_keys || []

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

        # A state a later version renamed: a run persisted in `old`
        # restores in `to` and carries on from there. Renames chain (a to
        # b, then b to c); a name is renamed at most once and never back
        # to a name it had. A name the class still declares is never taken
        # for an old one (validate_graph warns of such a rename). The
        # persisted run is mapped after migrate_from, before anything
        # checks its names, so a rename needs no persistence_schema_version.
        # A rename stays declared while runs persisted under its old name
        # may remain.
        def renamed_state(old, to:)
          @renamed_states = renamed_name_map(renamed_states, old, to, kind: "state")
        end

        # A transition a later version renamed: a run persisted about to
        # take `old`, or waiting in it (its wait, pending retry or batch),
        # restores at `to`, as renamed_state. A renamed transition keeps
        # its keys: its steps' idempotency keys and wait tokens are made
        # under the first name in its chain (transition_key_name), so a
        # step a deploy cut short, a retry or an early delivery meets the
        # keys its earlier attempt used. Hence at most one name is renamed
        # to a transition, and the rename stays declared for good: dropping
        # it moves the transition's keys to its new name.
        def renamed_transition(old, to:)
          renames = renamed_name_map(renamed_transitions, old, to, kind: "transition")
          earlier = renamed_transitions.key(renames.fetch(old.to_s))
          if earlier
            raise ArgumentError, "transition #{to.inspect} is already the new name of #{earlier.inspect}; a " \
                                 "transition keeps the keys of one first name, so only one name is renamed to it"
          end

          @renamed_transitions = renames
        end

        def renamed_states
          @renamed_states || {}.freeze
        end

        def renamed_transitions
          @renamed_transitions || {}.freeze
        end

        # The state a persisted state name stands for now, renames
        # followed, or nil when the class knows none. `O(R·(S + T))` for
        # `R` renamed states.
        def current_state_name(name)
          return if name.nil?

          resolve_state_name(follow_renames(name, renamed_states) { |candidate| resolve_state_name(candidate) })
        end

        # The transition a persisted transition name stands for now,
        # renames followed, or nil when the class knows none. `O(R·T)` for
        # `R` renamed transitions.
        def current_transition_name(name)
          return if name.nil?

          transition_named(follow_renames(name, renamed_transitions) { |candidate| transition_named(candidate) })&.name
        end

        # The name a transition's steps are keyed under (their idempotency
        # keys and wait tokens): the first name in its rename chain, so a
        # renamed transition keeps its keys. Renames have no cycles and at
        # most one name renamed to each, so the chain back is a line.
        # `O(R)` for `R` renamed transitions.
        def transition_key_name(name)
          earlier = renamed_transitions.invert
          current = name.to_s
          current = earlier[current] while earlier.key?(current)
          current
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
        # `:shared` (the default) keeps one transcript: each agent step sees
        # the session and its accepted output is appended to it. `:isolated`
        # keeps no transcript for agents: every agent step must declare
        # `input:`, its output is never appended, and `inject_state` does
        # not run for it.
        def session(mode = nil)
          return @session_mode || :shared if mode.nil?
          unless %i[shared isolated].include?(mode)
            raise ArgumentError, "session must be :shared or :isolated, got #{mode.inspect}"
          end

          @session_mode = mode
        end

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
        # kwarg. Memory, RedisStore, and CacheStore honour it;
        # ActiveRecordStore cannot expire state and refuses a non-nil TTL
        # before writing, which a persisted run reaches before its first
        # step. External duck-typed adapters that implement only the bare
        # REQUIRED_METHODS contract without a `ttl:` kwarg will only break
        # when a host actually opts into TTL.
        def persistence_ttl(seconds = nil)
          return @persistence_ttl if seconds.nil?

          unless seconds.is_a?(Numeric) && seconds.positive?
            raise ArgumentError,
                  "persistence_ttl must be a positive Numeric (seconds), got #{seconds.inspect}"
          end

          @persistence_ttl = seconds
        end

        def transitions_from(state)
          transitions_by_state.fetch(state, []).dup
        end

        def first_transition_from(state)
          transitions_by_state.fetch(state, []).first
        end

        def transition_from?(state)
          transitions_by_state.fetch(state, []).any?
        end

        def find_transition(name)
          (@transitions || {})[name]
        end

        # The transition whose name has this String form, for a name read
        # back from a payload. `O(T)`.
        def transition_named(name)
          return if name.nil?

          find_transition(name) ||
            (@transitions || {}).each_value.find { |transition| transition.name.to_s == name.to_s }
        end

        # A state this class can hold: declared with `state` (or
        # `initial_state`), or named by any transition's `from:` or `to:`.
        # Matched by String form, so a payload's "prepared" finds a state
        # declared as :prepared or "prepared". `O(S + T)`.
        def known_state?(name) = !resolve_state_name(name).nil?

        # The identifier this class declares for `name` (matched by String
        # form), or nil when the class knows no such state.
        def resolve_state_name(name)
          return if name.nil?

          wanted = name.to_s
          candidates = (@states || []) + (@transitions || {}).each_value.flat_map { |t| [t.from, t.to] }
          candidates.find { |candidate| !candidate.nil? && candidate.to_s == wanted }
        end

        def transition_at(index)
          (@transitions || {}).values.fetch(index)
        end

        def from_state(hash)
          workflow = allocate
          workflow.send(:restore_state, hash)
          workflow
        end

        private

        def own_identifier(identifier)
          Identifier.normalize(identifier, label: "workflow identifier")
        end

        # The renames with `old` renamed to `to`: refused when `old` is
        # already renamed, or when the chain from `to` leads back to `old`
        # (a rename back), so every chain is a line. `O(R)`.
        def renamed_name_map(renames, old, to, kind:)
          old_name = renamed_identifier(old, kind:)
          new_name = renamed_identifier(to, kind:)
          check_rename!(renames, old_name, new_name, kind:)
          renames.merge(old_name => new_name).freeze
        end

        def check_rename!(renames, old_name, new_name, kind:)
          if old_name == new_name
            raise ArgumentError, "a renamed #{kind} must differ from its new name, got #{old_name.inspect}"
          end

          if renames.key?(old_name)
            raise ArgumentError, "#{kind} #{old_name.inspect} is already renamed to #{renames[old_name].inspect}; " \
                                 "rename #{renames[old_name].inspect} instead"
          end

          return unless renamed_back?(renames, old_name, new_name)

          raise ArgumentError, "#{kind} #{new_name.inspect} was renamed from #{old_name.inspect}; a #{kind} is " \
                               "never renamed back to a name it had"
        end

        def renamed_back?(renames, old_name, new_name)
          current = new_name
          current = renames[current] while renames.key?(current) && current != old_name
          current == old_name
        end

        def renamed_identifier(name, kind:)
          unless (name.is_a?(Symbol) || name.is_a?(String)) && !name.to_s.strip.empty?
            raise ArgumentError, "a renamed #{kind} must be a non-blank Symbol or String, got #{name.inspect}"
          end

          name.to_s
        end

        # The name `name` stands for now: itself while the class declares
        # it (`declared` says so), else where its renames lead. Chains are
        # lines (renamed_name_map), so the walk ends. `O(R)` calls of
        # `declared`.
        def follow_renames(name, renames, &declared)
          current = name.to_s
          current = renames[current] until declared.call(current) || !renames.key?(current)
          current
        end

        def transitions_by_state
          @transitions_by_state ||= Hash.new { |index, state| index[state] = [] }
        end

        def transition_order
          @transition_order ||= {}
        end

        def transition_sequence
          @transition_sequence ||= 0
        end

        def insert_into_transition_index(transition)
          order = transition_order_for(transition.name)
          indexed = transitions_by_state[transition.from]
          insertion = indexed.bsearch_index { |candidate| transition_order.fetch(candidate.name) > order }
          indexed.insert(insertion || indexed.length, transition)
        end

        def transition_order_for(name)
          return transition_order.fetch(name) if transition_order.key?(name)

          transition_order[name] = transition_sequence
          @transition_sequence = transition_sequence + 1
          transition_order.fetch(name)
        end

        def duplicate_transition_index(source)
          source.to_h.each_with_object(Hash.new { |index, state| index[state] = [] }) do |(state, transitions), copy|
            copy[state] = transitions.dup
          end
        end

        def remove_from_transition_index(transition)
          return unless transition

          indexed = transitions_by_state[transition.from]
          indexed.delete(transition)
          transitions_by_state.delete(transition.from) if indexed.empty?
        end

        # A user redeclaration replacing a GENERATED transition takes a fresh
        # declaration-position order; a genuine user redefinition keeps its
        # original position (matrix-pinned redefinition semantics). Without
        # this, the synthetic :fail generated when `state :failed` is
        # declared keeps its early order number, and a later user-declared
        # :fail sharing an origin state with a primary transition would sort
        # ahead of it and shadow it at run time.
        def release_generated_transition_order(name)
          return unless generated_transitions.delete(name)

          transition_order.delete(name)
        end

        def generated_transitions
          @generated_transitions ||= []
        end

        def generate_fail_transition
          @transitions ||= {}
          return if @transitions.key?(:fail)

          generated_transitions << :fail
          transition(:fail, from: nil, to: :failed)
        end
      end
    end
  end
end
