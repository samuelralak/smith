# frozen_string_literal: true

require "time"

module Smith
  class Workflow
    # Batch mode (Smith::Batch). An attempt whose mode is :batch prepares its
    # agent call as a synchronous one would, admits it against the budget,
    # and captures the request instead of sending it (a fan-out captures each
    # branch's, in turn). Once the step's attempt has ended without error
    # (its context checks included), the requests go to
    # Smith.config.batch_queue under ids of the wait's token and the run waits
    # on `:batch_result`, recording its pending batch (the transition, the
    # attempt, its key generation, and each request's digest). Like any wait
    # it is not a step; BatchWait completes it. A step inside another run's
    # step (an in-process child) cannot wait, so it never sends a batch.
    module BatchExecution
      # Batches end within 24 hours; the wait allows one more.
      WAIT_SECONDS = 25 * 3600
      # The requests an attempt captured, for the step to queue.
      Captured = Data.define(:token, :requests, :attempt, :key_generation)

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
        arity = mode.is_a?(Proc) ? mode.arity : mode.method(:call).arity
        value = arity == 1 ? mode.call(context) : mode.call(context, @step_attempt || 1)
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
      # of the call before anything is sent), and its hold.
      def capture_batch_request(agent_class, prepared_input)
        @batch_capture = nil
        request = catch(Providers::BatchExchange::CAPTURED) do
          @batch_capturing = true
          invoke_agent(agent_class, prepared_input)
          nil
        ensure
          @batch_capturing = false
        end
        [request || raise(BatchModeUnavailable, "a batch step's agent made no provider request"), @batch_capture.hold]
      end

      def send_batch(transition, captures)
        refuse_batch_wait!
        token = wait_token_for(transition, ["batch", @step_attempt || 1])
        captured = captures.transform_values(&:call)
        hold_batch!(token, captured.transform_values(&:last))
        Captured.new(token:, requests: captured.transform_values(&:first), attempt: @step_attempt || 1,
                     key_generation: @step_key_generation || 0)
      end

      # The run can wait for a batch: a queue takes its requests, it is not
      # inside split-step execution or another run's step (an in-process
      # child), and the wait ends within the store's TTL.
      def refuse_batch_wait!
        Smith.config.batch_queue || raise(BatchQueueMissing)
        raise WorkflowError, "a batch step cannot wait inside split-step execution" if @split_step_phase == :executing
        raise WorkflowError, "an in-process child cannot wait for a batch" if Thread.current[:smith_step_depth].to_i > 1

        check_wait_ttl!(WAIT_SECONDS)
      end

      # Hands the captured requests to the queue and waits. The batch is the
      # attempt a pending retry waited to make, so the pending batch takes
      # its place.
      def queue_batch(transition, captured)
        ids = enqueue_requests(captured)
        @batch_holds = nil
        @pending_retry = nil
        @pending_batch = pending_batch_record(transition, captured, ids)
        @awaiting = WaitRecord.build_batch(transition, captured.token, WAIT_SECONDS, Time.now.utc, ids.length)
        record_wait_trace(transition, :waiting)
        WAIT_PENDING
      end

      # Enqueues each captured request under its custom id; returns them by id.
      def enqueue_requests(captured)
        ids = captured.requests.to_h { |branch_key, request| [Batch.custom_id(captured.token, branch_key), request] }
        ids.each do |custom_id, request|
          Smith.config.batch_queue.enqueue(custom_id:, await_token: captured.token, request:,
                                           execution_key: @persistence_key)
          # Handed off, it may be sent: its hold stays until its result, or
          # expires.
          @batch_holds&.delete(custom_id)
        end
        ids
      end

      def pending_batch_record(transition, captured, ids)
        { "transition" => transition.name.to_s, "attempt" => captured.attempt,
          "key_generation" => captured.key_generation, "requests" => ids.transform_values { Batch.digest(_1) } }.freeze
      end
    end
  end
end
