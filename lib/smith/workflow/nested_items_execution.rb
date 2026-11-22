# frozen_string_literal: true

module Smith
  class Workflow
    # A fan-out over items (Transition#workflow's `over:`): one nested run an
    # item, each in a branch of its own (its idempotency keys and usage
    # attributed to the item's index), at most `concurrency` at once, each
    # item's outcome its own (NestedExecution builds and runs each child).
    # Each item's run spends within an equal share of what the run's budget
    # has left in every dimension it bounds, held from it while the item runs
    # and settled at what it spent, so runs going at once never take one
    # another's room.
    module NestedItemsExecution
      Envelope = Struct.new(:reservation, :ledger)
      private_constant :Envelope

      private

      def execute_nested_items(transition)
        config = transition.nested_items
        items = nested_items_of(config)
        return [] if items.empty?

        env = items_environment(items.length)
        branches = items.each_with_index.map do |item, index|
          PreparedBranchExecution.instance_method(:prepared_branch).bind_call(
            self, NestedItemsExecution.instance_method(:run_nested_item), transition, index, item, env
          )
        end
        Parallel.execute(branches:, concurrency: config[:concurrency])
      end

      def items_environment(count)
        BranchEnv.new(prepared_input: nil, guardrail_sources: Tool.current_guardrails,
                      scoped_store: propagate_scoped_artifacts,
                      branch_estimates: item_shares(count),
                      deadline: wall_clock_deadline)
      end

      # Each item's share of what the run's budget has left, in every dimension.
      def item_shares(count)
        @ledger && @ledger.limits.keys.to_h { |dimension| [dimension, @ledger.remaining_share(dimension, count)] }
      end

      def nested_items_of(config)
        items = config[:over].call(snapshot_value(@context))
        raise WorkflowError, "a workflow step's over: must return an Array of items" unless items.is_a?(Array)

        limit = Smith.config.parallel_branch_limit
        raise WorkflowError, "a workflow step's items exceed the configured limit #{limit}" if items.length > limit

        snapshot_value(items)
      end

      def run_nested_item(transition, index, item, env, signal)
        with_branch_context(env, @ledger, attribution_overlay: { branch_key: index }) do
          check_cancellation!(signal)
          check_deadline!
          envelope = item_envelope(env)
          begin
            run_item_child(transition, item, envelope)
          ensure
            settle_item_envelope(envelope)
          end
        end
      end

      def run_item_child(transition, item, envelope)
        child = build_child_workflow(transition.workflow_class, item: [transition.nested_items[:item_to], item],
                                                                ledger: envelope&.ledger || @ledger)
        child_result = run_nested_item_child(child)
        reject_waiting_child!(child, child_result)
        nested_item_outcome(child_result)
      end

      # The item's share, held from the run's budget, and a budget of that
      # share for its run to spend within.
      def item_envelope(env)
        return unless @ledger && env.branch_estimates

        Envelope.new(reserve_branch_budget(@ledger, branch_estimates: env.branch_estimates),
                     Budget::Ledger.new(limits: env.branch_estimates))
      end

      def settle_item_envelope(envelope)
        return unless envelope

        spent = envelope.ledger.consumed
        @ledger.reconcile_many!(envelope.reservation, actual: envelope.ledger.limits.to_h { [_1, spent.fetch(_1, 0)] })
      end

      # A child that raised a refusal is that item's outcome, its usage kept.
      def run_nested_item_child(child)
        run_child_workflow(child)
      rescue OutputRefused => e
        { "refused" => e.message }
      end

      # The item's outcome: its output, or its refusal when its run ended on a
      # refused response, its own failure route taken or not (the refusal its
      # last failure, nothing after it giving output); any other failure fails
      # the step, as a nested workflow's does.
      def nested_item_outcome(child_result)
        return child_result if child_result.is_a?(Hash) && child_result.key?("refused")

        refused = ended_refused(child_result.steps)
        if refused
          roll_up_child_totals(child_result)
          return { "refused" => refused.message }
        end

        { "output" => handle_child_result(child_result) }
      end

      def ended_refused(steps)
        failed = steps.rindex { |step| step.key?(:error) }
        error = failed && steps[failed][:error]
        error if error.is_a?(OutputRefused) && steps.drop(failed + 1).all? { |step| step[:output].nil? }
      end
    end
  end
end
