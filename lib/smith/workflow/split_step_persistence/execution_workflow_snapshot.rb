# frozen_string_literal: true

require "dry-initializer"

require_relative "../../errors"
require_relative "../graph"
require_relative "transition_contract"

module Smith
  class Workflow
    module SplitStepPersistence
      class ExecutionWorkflowSnapshot
        extend Dry::Initializer

        param :workflow_class

        def self.capture(workflow_class, &)
          new(workflow_class).capture(&)
        end

        def capture
          @initial_state = workflow_class.initial_state
          @transitions = reachable_definition_transitions.map do |transition|
            yield transition if block_given?
            [transition.name, transition, TransitionContract.capture(transition)].freeze
          end.freeze
          freeze
        end

        def verify!
          unless workflow_class.initial_state == @initial_state
            raise WorkflowError, "authorized nested workflow definition changed before execution"
          end

          index = 0
          reachable_definition_transitions.each do |transition|
            expected = @transitions[index]
            verify_transition!(transition, expected)
            index += 1
          end
          return true if index == @transitions.length

          raise WorkflowError, "authorized nested workflow definition changed before execution"
        end

        private

        def reachable_definition_transitions
          Graph::Reachability.new(workflow_class.graph).each_transition.map do |transition|
            workflow_class.transition_at(transition.definition_index)
          end
        rescue IndexError
          raise WorkflowError, "authorized nested workflow definition changed before execution"
        end

        def verify_transition!(transition, expected)
          matches = expected &&
                    transition.name == expected.fetch(0) &&
                    transition.equal?(expected.fetch(1)) &&
                    TransitionContract.signature(transition) == expected.fetch(2)
          return if matches

          raise WorkflowError, "authorized nested workflow definition changed before execution"
        end
      end
    end
  end
end
