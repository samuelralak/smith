# frozen_string_literal: true

require_relative "../composite/branch_failure"
require_relative "../composite/contract"
require_relative "../composite/effects_baseline"
require_relative "../composite/effects_preflight"
require_relative "../composite/reducer"

module Smith
  class Workflow
    module SplitStepPersistence
      module CompositeReductionExecution
        include Composite::Contract

        private

        def reduce_authorized_composite_step!(authorization, plan:, input:, outcomes:, primary_failure: nil)
          authorization = validate_composite_authorization!(authorization)
          validate_composite_reduction_plan!(authorization, plan, input)
          reduction = Composite::Reducer.new(plan:, outcomes:, primary_failure:).call
          effects_application = prepare_composite_effects(reduction.effects)
          @composite_plan = plan
          @composite_input = input
          @composite_reduction = reduction
          @composite_effects_application = effects_application
          @execution_namespace = plan.execution_namespace
          Execution.instance_method(:execute_authorized_prepared_step!).bind_call(self, authorization)
        ensure
          @composite_plan = nil
          @composite_input = nil
          @composite_reduction = nil
          @composite_effects_application = nil
        end

        def apply_composite_reduction!(transition)
          reduction = @composite_reduction
          apply_composite_effects!(@composite_effects_application)
          restore_composite_session!
          if reduction.failed?
            raise Composite::BranchFailure.new(
              branch_key: reduction.failed_branch_key,
              error: reduction.error
            )
          end

          validate_composite_output!(transition, reduction.output)
          reduction.output
        end

        def restore_composite_session!
          @session_messages = snapshot_value(@composite_input.session_messages)
          @last_prepared_input = snapshot_value(@composite_input.agent_messages)
        end

        def prepare_composite_effects(effects)
          Composite::EffectsPreflight.new(
            effects:,
            baseline: composite_effect_baseline,
            snapshotter: method(:snapshot_value)
          ).call
        end

        def apply_composite_effects!(application)
          Thread.handle_interrupt(Object => :never) do
            @usage_mutex.synchronize do
              @tool_results_mutex.synchronize do
                validate_composite_effect_baseline!(application.baseline)
                @usage_entries = application.usage_entries.dup
                @total_tokens = application.total_tokens
                @total_cost = application.total_cost
                @tool_results = application.tool_results.dup
                @ledger = application.ledger
              end
            end
          end
        end

        def composite_effect_baseline
          @usage_mutex.synchronize do
            @tool_results_mutex.synchronize do
              build_composite_effect_baseline
            end
          end
        end

        def build_composite_effect_baseline
          ledger = @ledger
          Composite::EffectsBaseline.new(
            usage_entries: @usage_entries.dup,
            tool_results: snapshot_value(@tool_results),
            total_tokens: @total_tokens,
            total_cost: @total_cost,
            ledger:,
            budget_consumed: ledger ? ledger.consumed : {}
          )
        end

        def validate_composite_effect_baseline!(expected)
          current = build_composite_effect_baseline
          return if current == expected

          raise WorkflowError, "composite effect baseline changed before application"
        end

        def validate_composite_output!(transition, output)
          if @composite_plan.kind == :parallel
            agent = captured_agent(
              @split_step_active_execution_authorization,
              transition,
              @composite_plan.branches.first.agent,
              :agent
            )
            validate_data_volume!(output, agent)
            run_output_guardrails(output, agent)
          else
            run_workflow_output_guardrails(output)
          end
        end
      end
    end
  end
end
