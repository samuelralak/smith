# frozen_string_literal: true

require "time"

module Smith
  class Workflow
    # Batch mode (Smith::Batch). An attempt whose mode is :batch prepares its
    # agent call as a synchronous one would, admits it against the budget,
    # and captures the request instead of sending it (a fan-out captures each
    # branch's, in turn); the requests go to Smith.config.batch_queue under
    # ids of the wait's token, and the run waits on `:batch_result`, recording
    # its pending batch (the transition, the attempt and its key generation).
    # Like any wait it is not a step; BatchWait completes it.
    module BatchExecution
      # Batches end within 24 hours; the wait allows one more.
      WAIT_SECONDS = 25 * 3600

      private

      # The attempt sends its requests as a batch: its mode says so and no
      # result of it is being delivered.
      def batch_send?(transition)
        transition.batches? && !delivering_batch? && batch_mode_for(transition) == :batch
      end

      # A delivery runs only the stored batch wait's step (BatchWait).
      def delivering_batch? = !@batch_delivery.nil? && @pending_batch["attempt"] == (@step_attempt || 1)

      def batch_mode_for(transition)
        mode = transition.batch_mode
        return mode unless mode.respond_to?(:call)

        context = snapshot_value(@context)
        value = mode.arity == 1 ? mode.call(context) : mode.call(context, @step_attempt || 1)
        return value if %i[sync batch].include?(value)

        raise WorkflowError, "a mode: callable must return :sync or :batch, got #{value.inspect}"
      end

      # An agent step's batch: its one call.
      def send_agent_batch(transition, agent_class, prepared_input)
        send_batch(transition, nil => lambda do
          admit_batch_call { reserve_for_serial(transition, effective_call_ledger) }
          with_agent_context(agent_class) { capture_batch_request(agent_class, prepared_input) }
        end)
      end

      # A fan-out's batch: each branch's call, captured in its own branch
      # context (attribution, idempotency scope, budget share) in turn.
      def send_fanout_batch(transition, branches, branch_agent_classes, prepared_input)
        env = fanout_branch_environment(branches, branch_agent_classes, prepared_input)
        captures = branches.to_h do |branch_key, _agent_name|
          agent_class = branch_agent_classes.fetch(branch_key)
          [branch_key, -> { capture_fanout_branch(env, branch_key, agent_class) }]
        end
        send_batch(transition, captures)
      end

      def capture_fanout_branch(env, branch_key, agent_class)
        with_branch_context(env, @ledger, agent_class:, attribution_overlay: { branch_key: }) do
          with_agent_context(agent_class) do
            admit_batch_call do
              reserve_fanout_branch_call(effective_call_ledger, env.branch_estimates[branch_key], agent_class)
            end
            capture_batch_request(agent_class, env.prepared_input)
          end
        end
      end

      # The budget admits the call now; what it costs is charged when its
      # result comes.
      def admit_batch_call
        ledger = effective_call_ledger
        release_branch_budget(ledger, yield)
      end

      # The request the agent's call would send (BatchExchange throws it out
      # of the call before anything is sent).
      def capture_batch_request(agent_class, prepared_input)
        request = catch(Providers::BatchExchange::CAPTURED) do
          @batch_capturing = true
          invoke_agent(agent_class, prepared_input)
          nil
        ensure
          @batch_capturing = false
        end
        request || raise(BatchModeUnavailable, "a batch step's agent made no provider request")
      end

      def send_batch(transition, captures)
        queue = Smith.config.batch_queue || raise(BatchQueueMissing)
        raise WorkflowError, "a batch step cannot wait inside split-step execution" if @split_step_phase == :executing

        check_wait_ttl!(WAIT_SECONDS)
        token = wait_token_for(transition, ["batch", @step_attempt || 1])
        requests = captures.transform_values(&:call)
        requests.each do |branch_key, request|
          queue.enqueue(custom_id: Batch.custom_id(token, branch_key), await_token: token, request:,
                        execution_key: @persistence_key)
        end
        enter_batch_wait(transition, token, requests.length)
      end

      # The batch is the attempt a pending retry waited to make, so the
      # pending batch takes its place.
      def enter_batch_wait(transition, token, count)
        @pending_retry = nil
        @pending_batch = { "transition" => transition.name.to_s, "attempt" => @step_attempt || 1,
                           "key_generation" => @step_key_generation || 0 }.freeze
        @awaiting = WaitRecord.build_batch(transition, token, WAIT_SECONDS, Time.now.utc, count)
        record_wait_trace(transition, :waiting)
        WAIT_PENDING
      end
    end
  end
end
