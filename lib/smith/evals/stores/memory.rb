# frozen_string_literal: true

require_relative "../store"
require_relative "memory/tuning"

module Smith
  module Evals
    module Stores
      # Experimental. The eval store in memory (slice-1a design, 9.4), for
      # tests and the worked example: the interface and rules of
      # Smith::Evals::Store, one Mutex around everything, nothing durable and
      # nothing shared between processes or between two stores (a forked
      # child writes only to its own copy). It keeps each record's text and
      # reads it back as the file store does, so a value read is a fresh
      # frozen copy, and a read of lines yields those there when it began.
      # Tuning runs (slice 5a) are kept beside eval runs, by their own ids,
      # and never listed (Tuning). Each call is O(record), a read O(lines), a
      # listing O(R log R).
      class Memory
        include Tuning

        # clock: returns the Time a cancel request records.
        def initialize(clock: -> { Time.now })
          @clock = Store::Clock.check!(clock)
          @runs = {}
          @lock = Mutex.new
        end

        def create_record(scope:, header:)
          scope = Store::Records.scope!(scope)
          record = Store::Records.header!(header, scope)
          created(scope, record, Store::Listing.entry(record.value))
        end

        def read_header(scope:, eval_run_id:) = read(*ids!(scope, eval_run_id), &:header)

        def acquire_lease(scope:, eval_run_id: nil, tuning_run_id: nil)
          scope = Store::Records.scope!(scope)
          id = Store::TuningRecords.run_id!(eval_run_id, tuning_run_id)
          @lock.synchronize do
            run = run!(scope, id)
            raise RunBusy, "#{Store::TuningRecords.run_name(id)} #{id} is leased by another holder" if run.lease

            lease = Store::Lease.new(scope:, **Store::TuningRecords.run_key(id)) do
              @lock.synchronize { run.lease = nil if run.lease.equal?(lease) }
            end
            run.lease = lease
          end
        end

        def append_segment(scope:, eval_run_id:, segment:, lease:)
          scope, id = ids!(scope, eval_run_id)
          record = Store::Records.segment!(segment, id)
          append(scope, id, lease, :segment, record)
        end

        def append_trial(scope:, eval_run_id:, line:, lease:)
          scope, id = ids!(scope, eval_run_id)
          record = Store::Records.trial!(line, id)
          append(scope, id, lease, :trial, record)
        end

        def each_segment(scope:, eval_run_id:, &) = each_line(:each_segment, :segment, *ids!(scope, eval_run_id), &)
        def each_trial(scope:, eval_run_id:, &) = each_line(:each_trial, :trial, *ids!(scope, eval_run_id), &)

        def write_summary(scope:, eval_run_id:, summary:, lease:)
          scope, id = ids!(scope, eval_run_id)
          record = Store::Records.summary!(summary, scope, id)
          summarize(scope, id, lease, record)
        end

        def read_summary(scope:, eval_run_id:) = read(*ids!(scope, eval_run_id), &:summary)

        def list_records(scope:, limit: Store::Listing::DEFAULT_LIMIT, after: nil)
          digest = Smith::Scope.digest(Store::Records.scope!(scope))
          limit = Store::Listing.limit!(limit)
          cursor = Store::Listing.after!(after)
          @lock.synchronize do
            runs = @runs.filter_map { |(scope_digest, id), run| [id, run] if scope_digest == digest && run.entry }.to_h
            Store::Listing.listing(runs.values.map(&:entry), limit:, after: cursor) { runs.fetch(_1).status }
          end
        end

        def request_cancel(scope:, actor:, reason:, eval_run_id: nil, tuning_run_id: nil)
          scope = Store::Records.scope!(scope)
          id = Store::TuningRecords.run_id!(eval_run_id, tuning_run_id)
          record = Store::Records.cancel!(actor, reason, @clock.call)
          @lock.synchronize { run!(scope, id).request_cancel(record) }
        end

        def cancel_request(scope:, eval_run_id: nil, tuning_run_id: nil)
          read(Store::Records.scope!(scope), Store::TuningRecords.run_id!(eval_run_id, tuning_run_id), &:cancel)
        end

        private

        def ids!(scope, eval_run_id) = [Store::Records.scope!(scope), Store::Records.eval_run_id!(eval_run_id)]

        # entry: the listing's, nil for a tuning run, which is never listed.
        def created(scope, record, entry)
          @lock.synchronize do
            key = [Smith::Scope.digest(scope), record.key]
            next :exists if @runs.key?(key)

            @runs[key] = Run.new(record, entry)
            :created
          end
        end

        def run!(scope, id)
          @runs[[Smith::Scope.digest(scope), id]] or
            raise ArgumentError, "no #{Store::TuningRecords.run_name(id)} #{id} in this scope"
        end

        def append(scope, id, lease, kind, record)
          @lock.synchronize { run!(scope, id).held!(lease, id).append(kind, record, id) }
        end

        def summarize(scope, id, lease, record)
          @lock.synchronize { run!(scope, id).held!(lease, id).summarize(record) }
        end

        # Lines read from a copy taken under the lock, so the block may call
        # the store.
        def each_line(operation, kind, scope, id, &block)
          return enum_for(operation, scope:, **Store::TuningRecords.run_key(id)) unless block

          texts = @lock.synchronize { @runs[[Smith::Scope.digest(scope), id]]&.lines(kind).dup || [] }
          texts.each { block.call(Store::Records.read(_1)) }
          nil
        end

        def read(scope, id)
          text = @lock.synchronize { (run = @runs[[Smith::Scope.digest(scope), id]]) && yield(run) }
          text && Store::Records.read(text)
        end
      end
    end
  end
end

require_relative "memory/run"
