# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class ParallelAgentBinding
      extend Dry::Initializer

      param :workflow
      param :transition
      param :agent_class

      def initialize(...)
        super
        freeze
      end

      def resolve(workflow:, transition:)
        agent_class if @workflow.equal?(workflow) && @transition.equal?(transition)
      end
    end
  end
end
