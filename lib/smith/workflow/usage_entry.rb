# frozen_string_literal: true

module Smith
  class Workflow
    # One row per provider RESPONSE within an agent provider attempt.
    # `usage_id` is a UUID generated at recording time and stable across
    # persist/restore so hosts can use it as an idempotency anchor.
    #
    # `transition`, `branch_key`, `round`, and `workflow` come from the
    # ambient Smith::Attribution at recording time, so hosts can attribute
    # usage to the exact step, fan-out branch, optimizer round, and (for
    # nested workflows) the exact graph that spent it.
    # `attempt_id` is shared by every entry the same provider attempt
    # produced (an attempt with an N-round tool loop records N entries):
    # join on it against the `:provider_call` trace event for the attempt's
    # single measured duration; never sum a duration across entries. Every
    # attempt emits its `:provider_call` (an attempt aborted by a
    # non-provider error emits with `outcome: :aborted` before re-raising),
    # so prefix-accounted entries always have their join target.
    # All optional members are nil on entries restored from checkpoints written by
    # earlier Smith versions, and nil attribution members are omitted from
    # serialization so those documents re-serialize byte-identically.
    # rubocop:disable Style/RedundantStructKeywordInit
    UsageEntry = Struct.new(
      :usage_id,
      :agent_name,
      :model,
      :provider,
      :input_tokens,
      :output_tokens,
      :cost,
      :attempt_kind,
      :recorded_at,
      :transition,
      :branch_key,
      :round,
      :attempt_id,
      :workflow,
      keyword_init: true
    ) do
      def initialize(**attributes)
        attributes = attributes.transform_values do |value|
          value.is_a?(String) ? value.dup.freeze : value
        end
        super(**attributes) # rubocop:disable Style/SuperArguments
        freeze
      end

      # Serialization is additive only when present: nil attribution members
      # are omitted so an entry restored from a pre-attribution checkpoint
      # re-serializes byte-identically. Hosts that digest whole persisted
      # documents (exact-mutation proofs) depend on this stability.
      def to_h
        super.reject { |key, value| value.nil? && %i[transition branch_key round attempt_id workflow].include?(key) }
      end

      def self.from_h(hash)
        sym = hash.transform_keys(&:to_sym)
        filtered = sym.slice(*members)
        %i[agent_name provider attempt_kind transition branch_key].each do |attribute|
          filtered[attribute] = filtered[attribute].to_sym if filtered[attribute].is_a?(String)
        end
        new(**filtered)
      end
    end
    # rubocop:enable Style/RedundantStructKeywordInit
  end
end
