# frozen_string_literal: true

module Smith
  module Launchers
    # Runs each child to its end, one after another, in the parent's
    # process, and returns their results, so the parent's step completes at
    # once. For tests and scripts: a child that waits, or a long map, holds
    # the parent's step for as long as it runs.
    class Inline
      def inline? = true

      def launch(children:, parent_key:, await_token:) # rubocop:disable Lint/UnusedMethodArgument
        children.map do |child|
          ChildRun.result(ref: child.ref, run_result: child.build.run!)
        rescue StandardError
          { ref: child.ref, status: "failed", state: nil, output: nil }
        end
      end
    end
  end
end
