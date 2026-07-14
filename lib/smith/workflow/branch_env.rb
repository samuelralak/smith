# frozen_string_literal: true

module Smith
  class Workflow
    # rubocop:disable Style/RedundantStructKeywordInit
    BranchEnv = Struct.new(
      :prepared_input, :guardrail_sources, :scoped_store, :branch_estimates, :deadline, :agent_class,
      keyword_init: true
    ) do
      def setup_thread
        Smith::Tool.current_guardrails = guardrail_sources
        Smith::Tool.current_deadline = deadline
        Smith.scoped_artifacts = scoped_store
      end

      def teardown_thread
        Smith::Tool.current_guardrails = nil
        Smith::Tool.current_deadline = nil
        Smith.scoped_artifacts = nil
      end
    end
    # rubocop:enable Style/RedundantStructKeywordInit
  end
end
