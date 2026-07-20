# frozen_string_literal: true

require_relative "../composite/contract"
require_relative "../composite/input"
require_relative "../composite/planner"
require_relative "../composite/preparation"

module Smith
  class Workflow
    module SplitStepPersistence
      module CompositePreparation
        include Composite::Contract

        private

        def prepare_authorized_composite_step!(authorization)
          authorization = validate_composite_authorization!(authorization)
          transition = @split_step_transition
          specs = composite_branch_specs(authorization, transition)
          input = prepare_composite_input(authorization, transition, specs)
          plan = Composite::Planner.new(
            dispatch: authorization.dispatch_claim,
            kind: composite_kind(transition),
            transition: transition.name,
            from: transition.from,
            execution_namespace: execution_namespace,
            branch_specs: specs,
            input_digest: input.digest,
            budget_state_digest: composite_budget_state_digest
          ).call
          Composite::Preparation.new(plan:, input:)
        end

        def prepare_composite_input(authorization, transition, specs)
          ThreadContextSnapshot.new.around do
            run_composite_input_guardrails(authorization, transition, specs)
            agent_messages = build_session&.prepare!
            Composite::Input.build(agent_messages:, session_messages: snapshot_session_messages)
          end
        end

        def run_composite_input_guardrails(authorization, transition, specs)
          if transition.parallel?
            agent = specs.first.fetch(:agent)
            run_input_guardrails(captured_agent(authorization, transition, agent, :agent))
          else
            run_workflow_input_guardrails
            specs.each do |spec|
              agent = spec.fetch(:agent)
              run_agent_input_guardrails(captured_agent(authorization, transition, agent, :fanout_agent))
            end
          end
        end
      end
    end
  end
end
