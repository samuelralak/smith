# frozen_string_literal: true

module Smith
  module Tools
    class Think < Smith::Tool
      description "Think through your approach between steps. " \
                  "Plan what to do next, evaluate progress, and identify gaps."
      category :computation

      param :thought, type: :string, required: true

      def perform(thought:) # rubocop:disable Lint/UnusedMethodArgument
        { acknowledged: true }
      end
    end
  end
end
