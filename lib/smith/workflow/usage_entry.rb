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
      :input_tokens,
      :output_tokens,
      :cost,
      :attempt_kind,
      :recorded_at,
      keyword_init: true
    ) do
      def self.from_h(hash)
        sym = hash.transform_keys(&:to_sym)
        filtered = sym.slice(*members)
        filtered[:agent_name] = filtered[:agent_name].to_sym if filtered[:agent_name].is_a?(String)
        filtered[:attempt_kind] = filtered[:attempt_kind].to_sym if filtered[:attempt_kind].is_a?(String)
        new(**filtered)
      end
    end
    # rubocop:enable Style/RedundantStructKeywordInit
  end
end
