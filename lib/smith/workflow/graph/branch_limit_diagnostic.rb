# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # A parallel or fan-out step that declares more branches than
      # Smith.config.parallel_branch_limit allows.
      class BranchLimitDiagnostic
        extend Dry::Initializer

        option :transition
        option :workflow_class, optional: true

        def call
          branch_count = static_branch_count
          limit = Smith.config.parallel_branch_limit
          return unless branch_count && branch_count > limit

          Diagnostic.new(
            severity: :error,
            code: :parallel_branch_limit_exceeded,
            transition: transition.name,
            message: "Transition #{Reference.format(transition.name)} declares #{branch_count} parallel branches, " \
                     "exceeding the configured limit #{limit}.",
            suggestion: "Reduce the branch count or explicitly raise Smith.config.parallel_branch_limit."
          )
        end

        private

        def static_branch_count
          return transition.fanout_config.fetch(:branches).length if transition.fanout?

          transition.parallel_count if transition.parallel?
        end
      end
    end
  end
end
