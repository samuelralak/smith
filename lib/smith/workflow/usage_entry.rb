# frozen_string_literal: true

module Smith
  class Workflow
    # One row per agent provider call. `usage_id` is a UUID generated at
    # recording time and stable across persist/restore so hosts can use it as an
    # idempotency anchor.
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
      keyword_init: true
    ) do
      def initialize(**attributes)
        attributes = attributes.transform_values do |value|
          value.is_a?(String) ? value.dup.freeze : value
        end
        super(**attributes) # rubocop:disable Style/SuperArguments
        freeze
      end

      def self.from_h(hash)
        sym = hash.transform_keys(&:to_sym)
        filtered = sym.slice(*members)
        %i[agent_name provider attempt_kind].each do |attribute|
          filtered[attribute] = filtered[attribute].to_sym if filtered[attribute].is_a?(String)
        end
        new(**filtered)
      end
    end
    # rubocop:enable Style/RedundantStructKeywordInit
  end
end
