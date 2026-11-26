# frozen_string_literal: true

require_relative "../identity"
require_relative "../store/clock"

module Smith
  module Evals
    class Runner
      # Internal. One launch's trials (slice-1a design, 5.6 and 5.7): those
      # not yet done, in plan order, worked by C = the plan's concurrency
      # threads, each carrying the caller's attribution. Before a trial
      # starts, the store's cancel flag is read, then the queue; a cancel, a
      # run-stopping outcome or the store failing (an append, or the flag's
      # read) halts the queue, so no trial starts and those running finish
      # and record. A trial that ended in a retried error goes back with a
      # not-before time: min(30, 2**attempt) seconds, or none with the
      # driver's `retry_waits: :immediate`. Every line is appended outside
      # the driver's isolation. `call` gives the stop that halted it, or
      # nil, once every worker has stopped, even when its caller is
      # interrupted (a Timeout, a thread killed), so no worker appends after
      # the runner lets go of the lease.
      class Launch
        def initialize(plan, record:, lease:, segment:, store:)
          @plan = plan
          @record = record
          @lease = lease
          @segment = segment
          @store = store
          @trials = TrialRun.new(plan, record)
          @appended = 0
          @lock = Mutex.new
        end

        # How many trial lines this launch appended.
        def appended = @lock.synchronize { @appended }

        # done: the trial ids already final. Once every worker has stopped,
        # re-raises what one could not rescue.
        def call(done)
          @queue = Queue.new(waiting(done))
          @failure = nil
          @workers = []
          attribution = Smith::Attribution.current
          @plan.concurrency.times { @workers << worker(attribution) }
          @workers.each(&:join)
          raise @failure if @failure

          @queue.stop
        ensure
          # Interrupted: no trial starts, and those running record their
          # lines before the runner lets go of the lease.
          if @workers&.any?(&:alive?)
            @queue.halt(:failed)
            @workers.each(&:join)
          end
        end

        private

        def waiting(done)
          @plan.trials.each_with_index.filter_map do |(index, sample), position|
            id = Identity.trial_id(eval_run_id: @record.eval_run_id, sample_id: sample.id, index:)
            Queue::Item.new(position:, index:, sample:, tried: nil, not_before: nil) unless done.include?(id)
          end
        end

        # A worker always ends normally, so joining it never raises: what
        # stopped it (no StandardError, as a kill stops a process) stops the
        # launch, and `call` raises the first such once every worker ended.
        def worker(attribution)
          Thread.new do
            Smith::Attribution.carrying(attribution) { work }
          rescue Exception => e # rubocop:disable Lint/RescueException -- call raises it once every worker ended
            @lock.synchronize { @failure ||= e }
            @queue.halt(:failed)
          end
        end

        def work
          while (item = @queue.take)
            next @queue.done if item.tried.nil? && (cancelled? || @queue.halted?)

            item.tried && @queue.halted? ? recorded(item.tried) : attempted(item)
          end
        end

        def attempted(item)
          tried = @trials.attempt(item)
          return recorded(tried) unless @trials.retry?(tried) && !@queue.halted?

          @queue.put_back(item.with(tried:, not_before: not_before(tried.attempts.size)))
        end

        # Appends the trial's line, outside the driver's isolation; a
        # run-stopping outcome, or the store failing, halts the launch.
        def recorded(tried)
          trial_id = tried.spec.trial_id
          outcome = tried.attempts.last.outcome
          append(@trials.line(tried, @segment), trial_id)
          @queue.halt(stop(outcome.reason, trial_id)) if outcome.stops_run
        ensure
          @queue.done
        end

        def append(line, trial_id)
          @store.append_trial(scope: @plan.scope, eval_run_id: @record.eval_run_id, line:, lease: @lease)
          @lock.synchronize { @appended += 1 }
        rescue StoreError => e
          store_failed(e, trial_id)
        end

        def cancelled?
          request = @store.cancel_request(scope: @plan.scope, eval_run_id: @record.eval_run_id)
          return false if request.nil?

          @queue.halt({ "reason" => { "code" => "cancelled", "by" => "operator", "detail" => request["reason"] },
                        "actor" => request["actor"], "at" => request["at"], "trial_id" => nil })
          true
        rescue StoreError => e
          store_failed(e, nil)
          true
        end

        # The store failing stops the run (design 6.4): trial_id names the
        # trial whose line it lost, if one.
        def store_failed(error, trial_id)
          @queue.halt(stop({ "code" => "store_error", "by" => "infrastructure",
                             "detail" => "the store failed in #{error.operation}" }, trial_id))
        end

        def not_before(attempts)
          wait = @plan.driver.retry_waits == :immediate ? 0 : [30, 2**attempts].min
          Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
        end

        def stop(reason, trial_id)
          { "reason" => reason, "actor" => nil, "at" => Store::Clock.timestamp(Time.now), "trial_id" => trial_id }
        end
      end
    end
  end
end
