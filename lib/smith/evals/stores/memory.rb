# frozen_string_literal: true

require_relative "../store"

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
      # Each call is O(record), a read O(lines), a listing O(R log R).
      class Memory
        # clock: returns the Time a cancel request records.
        def initialize(clock: -> { Time.now })
          @clock = Store::Clock.check!(clock)
          @runs = {}
          @lock = Mutex.new
        end

        def create_record(scope:, header:)
          scope = Store::Records.scope!(scope)
          record = Store::Records.header!(header, scope)
          @lock.synchronize do
            key = [Smith::Scope.digest(scope), record.key]
            next :exists if @runs.key?(key)

            @runs[key] = Run.new(record)
            :created
          end
        end

        def read_header(scope:, eval_run_id:) = read(scope, eval_run_id, &:header)

        def acquire_lease(scope:, eval_run_id:)
          scope, id = ids!(scope, eval_run_id)
          @lock.synchronize do
            run = run!(scope, id)
            raise RunBusy, "eval run #{id} is leased by another holder" if run.lease

            lease = Store::Lease.new(scope:, eval_run_id: id) do
              @lock.synchronize { run.lease = nil if run.lease.equal?(lease) }
            end
            run.lease = lease
          end
        end

        def append_segment(scope:, eval_run_id:, segment:, lease:)
          scope, id = ids!(scope, eval_run_id)
          record = Store::Records.segment!(segment, id)
          @lock.synchronize { run!(scope, id).held!(lease, id).append(:segment, record, id) }
        end

        def append_trial(scope:, eval_run_id:, line:, lease:)
          scope, id = ids!(scope, eval_run_id)
          record = Store::Records.trial!(line, id)
          @lock.synchronize { run!(scope, id).held!(lease, id).append(:trial, record, id) }
        end

        def each_segment(scope:, eval_run_id:, &) = each_line(:each_segment, :segments, scope, eval_run_id, &)
        def each_trial(scope:, eval_run_id:, &) = each_line(:each_trial, :trials, scope, eval_run_id, &)

        def write_summary(scope:, eval_run_id:, summary:, lease:)
          scope, id = ids!(scope, eval_run_id)
          record = Store::Records.summary!(summary, scope, id)
          @lock.synchronize { run!(scope, id).held!(lease, id).summarize(record) }
        end

        def read_summary(scope:, eval_run_id:) = read(scope, eval_run_id, &:summary)

        def list_records(scope:, limit: Store::Listing::DEFAULT_LIMIT, after: nil)
          digest = Smith::Scope.digest(Store::Records.scope!(scope))
          limit = Store::Listing.limit!(limit)
          cursor = Store::Listing.after!(after)
          @lock.synchronize do
            runs = @runs.filter_map { |(scope_digest, id), run| [id, run] if scope_digest == digest }.to_h
            Store::Listing.listing(runs.values.map(&:entry), limit:, after: cursor) { runs.fetch(_1).status }
          end
        end

        def request_cancel(scope:, eval_run_id:, actor:, reason:)
          scope, id = ids!(scope, eval_run_id)
          record = Store::Records.cancel!(actor, reason, @clock.call)
          @lock.synchronize { run!(scope, id).request_cancel(record) }
        end

        def cancel_request(scope:, eval_run_id:) = read(scope, eval_run_id, &:cancel)

        private

        def ids!(scope, eval_run_id) = [Store::Records.scope!(scope), Store::Records.eval_run_id!(eval_run_id)]

        def run!(scope, id)
          @runs[[Smith::Scope.digest(scope), id]] or raise ArgumentError, "no eval run #{id} in this scope"
        end

        # Lines read from a copy taken under the lock, so the block may call
        # the store.
        def each_line(operation, kind, scope, eval_run_id, &block)
          scope, id = ids!(scope, eval_run_id)
          return enum_for(operation, scope:, eval_run_id:) unless block

          texts = @lock.synchronize { @runs[[Smith::Scope.digest(scope), id]]&.public_send(kind).dup || [] }
          texts.each { block.call(Store::Records.read(_1)) }
          nil
        end

        def read(scope, eval_run_id)
          scope, id = ids!(scope, eval_run_id)
          text = @lock.synchronize { (run = @runs[[Smith::Scope.digest(scope), id]]) && yield(run) }
          text && Store::Records.read(text)
        end
      end
    end
  end
end

require_relative "memory/run"
