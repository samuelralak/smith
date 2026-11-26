# frozen_string_literal: true

require_relative "errors"
require_relative "eval_run"
require_relative "identity"
require_relative "record"
require_relative "summary"
require_relative "store/clock"
require_relative "runner/queue"
require_relative "runner/trial_run"
require_relative "runner/launch"

module Smith
  module Evals
    # Experimental. Runs a Plan in one process and writes its record
    # (slice-1a design, 4.6, 5.6, 5.7, 6.4). The eval store is the resume
    # ledger:
    #
    # 1. The run's id is the one given, else the idempotency key's (the
    #    same key, scope and suite give the same id), else random.
    # 2. The header is created if absent. A record that exists must have
    #    been started with the same plan digest, finished or not, or the
    #    start raises ResumeMismatch naming what differs; one with a summary
    #    is finished and returned as it is, nothing run.
    # 3. The run's lease is taken (RunBusy while another process holds it);
    #    a run another start finished meanwhile is returned as it is, else a
    #    launch line is appended: segment 1 starts it, each later one
    #    resumes it.
    # 4. Each trial with an effective line (other than not_run) is done and
    #    never runs again, so nothing recorded is paid for twice; a trial a
    #    kill interrupted has no line and runs again.
    # 5. The rest run (Launch), recorded with the bounds the header names,
    #    and the summary is written from the store's lines: succeeded when
    #    every planned trial has a line, else failed (a run-stopping error,
    #    or the store failing) or cancelled.
    #
    # The lease is released whatever happens; an error the runner does not
    # rescue (one that is no StandardError, as a kill stops a process)
    # leaves the run resumable. O(L) to index L lines, O(T) memory.
    class Runner
      # What a header's plan digest is made of, for ResumeMismatch.
      PLAN_FIELDS = { "suite.version" => %w[suite version], "dataset.version" => %w[dataset version],
                      "selection" => %w[selection], "plan.trials_per_sample" => %w[plan trials_per_sample],
                      "candidate" => %w[candidate], "subject.variant" => %w[subject variant] }.freeze

      def initialize(plan, store:, config:)
        @plan = plan
        @store = store
        @config = config
        @scope = plan.scope
      end

      def call(eval_run_id: nil, idempotency_key: nil, started_by: nil)
        id = run_id(eval_run_id, idempotency_key)
        header = Record.header(@plan, eval_run_id: id, idempotency_key:, started_by:, created_at: Time.now,
                                      config: @config)
        stored = created(header)
        record = Record.new(store: @store, scope: @scope, eval_run_id: id, header: stored)
        return EvalRun.new(record) if record.summary

        lease = @store.acquire_lease(scope: @scope, eval_run_id: id)
        begin
          launched(record, lease, started_by) unless record.summary
        ensure
          lease.release
        end
        EvalRun.new(record)
      end

      private

      def run_id(given, key)
        named = -> { Identity.eval_run_id(key:, scope: @scope, suite: @plan.manifest.fetch("name")) }
        return named.call if given.nil?
        unless Identity::EVAL_RUN_ID.match?(given)
          raise ArgumentError, "an eval run id is er_ and 32 lowercase hex digits"
        end
        return given if key.nil? || given == named.call

        raise ArgumentError, "eval run #{given} is not the run idempotency key #{key.inspect} names"
      end

      # The header kept for the run: the one written now, or the stored one
      # when its plan digest matches.
      def created(header)
        return header if @store.create_record(scope: @scope, header:) == :created

        stored = @store.read_header(scope: @scope, eval_run_id: header["eval_run_id"])
        return stored if stored.dig("plan", "plan_digest") == header.dig("plan", "plan_digest")

        fields = PLAN_FIELDS.reject { |_name, path| stored.dig(*path) == header.dig(*path) }.keys
        fields = ["plan.plan_digest"] if fields.empty?
        raise ResumeMismatch.new("eval run #{header["eval_run_id"]} was started with another plan: " \
                                 "#{fields.join(", ")} differ", fields:)
      end

      def launched(record, lease, started_by)
        done = done_trials(record)
        segment = segment!(record, lease, started_by, done.size)
        launch = Launch.new(@plan, record:, lease:, segment:, store: @store)
        stop = launch.call(done)
        finish(record, lease, stop, complete: done.size + launch.appended == @plan.planned_trials)
      end

      # Appends this launch's line; its number.
      def segment!(record, lease, started_by, already)
        number = record.segments.size + 1
        @store.append_segment(scope: @scope, eval_run_id: record.eval_run_id, lease:,
                              segment: Record.segment(eval_run_id: record.eval_run_id, number:, started_by:,
                                                      started_at: Time.now, already:, config: @config))
        number
      end

      # The trial ids whose effective line is final (any outcome but not_run).
      def done_trials(record)
        effective = {}
        record.each_line do |line|
          kept = effective[line["trial_id"]]
          effective[line["trial_id"]] = line if kept.nil? || line["trial_revision"] > kept["trial_revision"]
        end
        effective.reject { |_id, line| line["outcome"] == "not_run" }.keys.to_set
      end

      # Succeeded when every planned trial has its line, so with no stop (a
      # launch reads the cancel flag only before a trial's first attempt);
      # failed when a run-stopping error or the store stopped it; cancelled
      # otherwise.
      def finish(record, lease, stop, complete:)
        status = if stop && stop.dig("reason", "code") != "cancelled" then "failed"
                 elsif complete then "succeeded"
                 else "cancelled"
                 end
        summary = Summary.build(header: record.header, segments: record.segments, lines: record.each_line,
                                samples: @plan.samples, status:, stop:, ended_at: Store::Clock.timestamp(Time.now))
        @store.write_summary(scope: @scope, eval_run_id: record.eval_run_id, summary:, lease:)
      end
    end
  end
end
