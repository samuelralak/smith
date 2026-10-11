# frozen_string_literal: true

require "time"

module Smith
  class Workflow
    # Completing a batch step's wait (BatchExecution). `resume!` with the
    # results (`{custom_id => result}`, every request's), or `expire_wait!`
    # past the deadline (every result then `missing`), runs the step again at
    # its attempt: each call takes its result instead of going over the wire,
    # parsed by RubyLLM's own provider parser, if the request it renders now
    # is the one sent, and the step goes on as after a synchronous call
    # (usage with `mode: :batch`, output checks, a follow-up call over the
    # wire, guardrails, `output_to:`, retries). Results are taken only by the
    # batch's own attempt; a succeeded one no call took (a branch cancelled
    # by a sibling's failure) is charged all the same (BatchCharges).
    module BatchWait
      PENDING_BATCH_FIELDS = %w[attempt key_generation requests transition].freeze
      DIGEST = /\A\h{64}\z/
      private_constant :PENDING_BATCH_FIELDS, :DIGEST

      private

      # [attempts already made, key generation] where a delivered batch's
      # step starts again, or nil. A delivery runs only the stored batch
      # wait's step, whose pending batch restore guarantees.
      def pending_batch_position
        [@pending_batch["attempt"] - 1, @pending_batch["key_generation"]] if @batch_delivery
      end

      # The step's branches in the wait's order (nil for an agent step).
      def batch_branches(transition) = transition.fanout? ? transition.fanout_config.fetch(:branches).keys : [nil]

      def batch_ids(transition, token)
        batch_branches(transition).to_h { |branch_key| [branch_key, Batch.custom_id(token, branch_key)] }
      end

      def batch_results!(transition, payload)
        ids = batch_ids(transition, @awaiting.fetch("token"))
        results = Batch.results!(payload, ids.values)
        batch_entries(ids) { |id| results.fetch(id) }
      rescue StandardError
        @wait_claimed = false
        raise
      end

      def missing_batch_results(transition)
        batch_entries(batch_ids(transition, @awaiting.fetch("token"))) { { "type" => Batch::MISSING }.freeze }
      end

      def batch_entries(ids)
        digests = @pending_batch.fetch("requests")
        ids.to_h { |branch_key, id| [branch_key, Batch::Delivery::Entry.new(yield(id), digests.fetch(id))] }
      end

      # The step runs again at the batch's attempt, each call taking its
      # result. It may enter another wait (a batch sent again, or a durable
      # retry's backoff); otherwise it counts. A completion that raises
      # leaves the run waiting.
      def complete_batch_wait(transition, entries, done)
        record = @awaiting
        @awaiting = nil
        @batch_delivery = Batch::Delivery.new(entries)
        step = with_step_context(transition) do
          Execution.instance_method(:execute_step_body).bind_call(self, transition)
        ensure
          charge_untaken_batch_results(transition)
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

      # The result a call of the batch's attempt takes, once (a follow-up
      # call, or a later attempt's, goes over the wire), for its branch.
      def take_batch_result = (@batch_delivery.take(Attribution.current&.branch_key) if delivering_batch?)

      def batch_result_due? = (delivering_batch? && @batch_delivery.for?(Attribution.current&.branch_key)) || false

      # A persisted pending batch names the stored batch wait's transition
      # (which WaitRecord checked is still a batch step), an attempt its
      # retry policy allows, a key generation only a declared
      # `new_idempotency_key_on` moves, and the digest of each request the
      # step's branches send; a stored batch wait needs one. Anything else
      # raises SerializationError.
      def restore_pending_batch(value)
        return if value.nil? && !batch_waiting?

        record = value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
        raise Smith::SerializationError, "persisted workflow pending_batch is invalid" unless
          well_formed_pending_batch?(record)

        record.transform_values(&:freeze).freeze
      end

      def well_formed_pending_batch?(record)
        transition = self.class.transition_named(@awaiting["transition"]) if batch_waiting?
        transition && record.keys.sort == PENDING_BATCH_FIELDS && record["transition"] == transition.name.to_s &&
          allowed_batch_position?(transition, *record.values_at("attempt", "key_generation")) &&
          batch_digests?(transition, record["requests"])
      end

      def allowed_batch_position?(transition, attempt, generation)
        config = transition.retry_config
        attempt.is_a?(Integer) && attempt.between?(1, config&.fetch(:attempts) || 1) && generation.is_a?(Integer) &&
          generation.between?(0, config&.key?(:new_idempotency_key_on) ? attempt - 1 : 0)
      end

      def batch_digests?(transition, requests)
        requests.is_a?(Hash) && requests.keys.sort == batch_ids(transition, @awaiting["token"]).values.sort &&
          requests.values.all? { _1.is_a?(String) && DIGEST.match?(_1) }
      end
    end
  end
end
