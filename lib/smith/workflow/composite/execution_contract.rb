# frozen_string_literal: true

require_relative "payload_digest"

module Smith
  class Workflow
    module Composite
      module ExecutionContract
        private

        def validate_composite_dispatch!(authorization, plan)
          validate_composite_dispatch_value!(authorization, plan.dispatch)
        end

        def validate_composite_dispatch_value!(authorization, dispatch)
          return if dispatch.to_h == authorization.dispatch_claim.to_h

          raise WorkflowError, "composite plan does not belong to the prepared dispatch"
        end

        def validate_composite_input!(plan, input)
          validate_composite_input_digest!(plan.input_digest, input)
        end

        def validate_composite_input_digest!(expected_digest, input)
          return if input.digest == expected_digest

          raise WorkflowError, "composite input does not match plan"
        end

        def validate_composite_budget_state!(plan)
          validate_composite_budget_state_digest!(plan.budget_state_digest)
        end

        def validate_composite_budget_state_digest!(expected_digest)
          return if expected_digest == composite_budget_state_digest

          raise WorkflowError, "composite plan budget state has changed"
        end

        def validate_composite_execution_namespace!(plan)
          validate_composite_execution_namespace_value!(plan.execution_namespace)
        end

        def validate_composite_execution_namespace_value!(expected_namespace)
          return if @execution_namespace.nil? || @execution_namespace == expected_namespace

          raise WorkflowError, "composite plan execution namespace has changed"
        end

        def validate_composite_transition_identity!(plan, transition)
          validate_composite_transition_values!(plan, transition)
        end

        def validate_composite_transition_values!(contract, transition)
          expected = [transition.name.to_s, transition.from.to_s, composite_kind(transition)]
          return if expected == [contract.transition, contract.from, contract.kind]

          raise WorkflowError, "composite plan does not match the prepared transition"
        end

        def composite_kind(transition)
          transition.parallel? ? :parallel : :fanout
        end

        def composite_budget_state_digest
          state = @ledger ? { limits: @ledger.limits, consumed: @ledger.consumed } : { limits: {}, consumed: {} }
          PayloadDigest.call(state)
        end
      end
    end
  end
end
