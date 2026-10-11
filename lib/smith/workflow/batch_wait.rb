# frozen_string_literal: true

require "time"

module Smith
  class Workflow
    # Completing a batch step's wait (BatchExecution). `resume!` with the
    # results (`{custom_id => result}`, every request's), or `expire_wait!`
    # past the deadline (every result then `missing`), runs the step again at
    # its attempt: each call takes its result instead of going over the wire,
    # parsed by RubyLLM's own provider parser, and the step goes on as after a
    # synchronous call (usage with `mode: :batch`, output checks, a follow-up
    # call over the wire, guardrails, `output_to:`, retries). A result already
    # paid for is charged even past a budget.
    module BatchWait
      PENDING_BATCH_FIELDS = %w[attempt key_generation transition].freeze
      private_constant :PENDING_BATCH_FIELDS

      private

      # [attempts already made, key generation] where a delivered batch's
      # step starts again, or nil. A delivery runs only the stored batch
      # wait's step, whose pending batch restore guarantees.
      def pending_batch_position
        [@pending_batch["attempt"] - 1, @pending_batch["key_generation"]] if @batch_delivery
      end

      # The step's branches in the wait's order (nil for an agent step).
      def batch_branches(transition) = transition.fanout? ? transition.fanout_config.fetch(:branches).keys : [nil]

      def batch_results!(transition, payload)
        token = @awaiting.fetch("token")
        ids = batch_branches(transition).to_h { |branch_key| [branch_key, Batch.custom_id(token, branch_key)] }
        results = Batch.results!(payload, ids.values)
        ids.transform_values { |id| results.fetch(id) }
      rescue StandardError
        @wait_claimed = false
        raise
      end

      def missing_batch_results(transition)
        batch_branches(transition).to_h { |branch_key| [branch_key, { "type" => Batch::MISSING }.freeze] }
      end

      # The step runs again at the batch's attempt, each call taking its
      # result. It may enter another wait (a batch sent again, or a durable
      # retry's backoff); otherwise it counts. A completion that raises
      # leaves the run waiting.
      def complete_batch_wait(transition, results, done)
        record = @awaiting
        @awaiting = nil
        @batch_delivery = Batch::Delivery.new(results)
        step = with_step_context(transition) do
          Execution.instance_method(:execute_step_body).bind_call(self, transition)
        end
        settle_batch_wait(step)
        return done if wait_pending?(step)

        step.key?(:error) && done == :resumed ? :failed : done
      rescue Exception # rubocop:disable Lint/RescueException -- the wait outlives a completion that did not happen
        @awaiting ||= record
        raise
      ensure
        @batch_delivery = nil
        @wait_claimed = false
      end

      def settle_batch_wait(step)
        @pending_batch = nil unless batch_waiting?
        return if wait_pending?(step)

        @step_count += 1
        @updated_at = Time.now.utc.iso8601(6)
        record_step_snapshot(step)
      end

      def batch_waiting? = @awaiting&.fetch("kind") == "batch"

      # The result a call of the step takes, once (a follow-up call goes over
      # the wire), for the branch it runs in.
      def take_batch_result = @batch_delivery&.take(Attribution.current&.branch_key)

      def batch_result_due? = @batch_delivery&.for?(Attribution.current&.branch_key) || false

      # A call whose result has come is reserved for whatever the budget has
      # left, never refused: the money is spent (BudgetIntegration's, else).
      def reserve_estimates!(ledger, estimates)
        return super unless batch_result_due?

        Thread.current[:smith_call_reservation] = ledger.reserve_spent!(estimates)
      end

      # A persisted pending batch names the stored batch wait's transition
      # (which WaitRecord checked is still a batch step), an attempt from 1
      # and a key generation an earlier attempt could reach; a stored batch
      # wait needs one. A malformed one raises SerializationError.
      def restore_pending_batch(value)
        return if value.nil? && !batch_waiting?

        record = value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
        pending_batch_transition(record)
        record.transform_values(&:freeze).freeze
      end

      def pending_batch_transition(record)
        transition = self.class.transition_named(@awaiting["transition"]) if batch_waiting?
        return transition if transition && well_formed_pending_batch?(transition, record)

        raise Smith::SerializationError, "persisted workflow pending_batch is invalid"
      end

      def well_formed_pending_batch?(transition, record)
        attempt, generation = record.values_at("attempt", "key_generation")
        record.keys.sort == PENDING_BATCH_FIELDS && record["transition"] == transition.name.to_s &&
          attempt.is_a?(Integer) && attempt >= 1 && generation.is_a?(Integer) && generation.between?(0, attempt - 1)
      end
    end
  end
end
