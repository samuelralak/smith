# frozen_string_literal: true

require_relative "../store"
require_relative "file/tuning"

module Smith
  module Evals
    module Stores
      # Experimental; its v1 layout is frozen with slice 1a.3. The eval store
      # in a folder (slice-1a design, 9.2 to 9.4), Smith's default:
      #
      #   <root>/v1/scopes/<scope digest>/scope.json      the scope, written once
      #   <root>/v1/scopes/<scope digest>/runs/<eval_run_id>/
      #     header.json, segments.jsonl, trials.jsonl, summary.json, cancel.json
      #     lease (a runner's flock for its life), tmp/
      #   <root>/v1/scopes/<scope digest>/tuning/<tuning_run_id>/  (slice 5a)
      #     header.json, lines.jsonl, summary.json, cancel.json, lease, tmp/
      #
      # A tuning run's folder is kept by the same rules as an eval run's,
      # and is never listed (Tuning).
      #
      # A run's folder reads as the published example records do. Headers
      # and cancel flags are created whole and never clobbered, a summary is
      # replaced whole, lines are appended (Documents, Lines). Every write is
      # flushed to the drive before it returns (F_FULLFSYNC on macOS, fsync
      # elsewhere): the line, or the temporary before its link or rename,
      # then the folder that gained a name; each create and each lease also
      # flush every folder from the root down to the run's. A lease is a
      # flock the operating system frees when its process dies, kill -9
      # included, and a forked child never holds (Writes). Nothing leaves the
      # root, and the store trusts whoever can write it (Paths). flock is
      # reliable on local file systems only; a host with a shared one uses a
      # database store. The root is made absolute when the store is built,
      # and nothing is written before the first write. Costs: every page of a
      # listing reads every header in the scope, O(R log R) (1 to 1.5 s a
      # page at 2,000 runs on a laptop), and records read at 4 to 5 MB/s
      # (the strict reader), so a resume reads a run's lines twice, once for
      # the runner and once for the first append's ids; a hosted product
      # uses a database store (slice 3a).
      class File
        include Tuning

        # The line file each append writes.
        APPENDS = { append_segment: :segment, append_trial: :trial, append_tuning_line: :tuning_line }.freeze
        private_constant :APPENDS

        attr_reader :root

        # root: the store's folder (a path); clock: returns the Time a cancel
        # request records.
        def initialize(root:, clock: -> { Time.now })
          unless (root.is_a?(String) || root.respond_to?(:to_path)) && !root.to_s.empty?
            raise ArgumentError, "root is a folder path"
          end

          @root = ::File.expand_path(root.to_s).freeze
          @clock = Store::Clock.check!(clock)
          @paths = Paths.new(@root)
          @runs = Runs.new(@paths)
          @writes = Writes.new(@paths)
        end

        def create_record(scope:, header:)
          scope = Store::Records.scope!(scope)
          create(:create_record, scope, Store::Records.header!(header, scope))
        end

        def read_header(scope:, eval_run_id:) = document(:read_header, *ids!(scope, eval_run_id), "header.json")

        def acquire_lease(scope:, eval_run_id: nil, tuning_run_id: nil)
          scope = Store::Records.scope!(scope)
          id = Store::TuningRecords.run_id!(eval_run_id, tuning_run_id)
          guarded(:acquire_lease) { @writes.lease(@runs.recorded!(scope, id), scope, id) }
        end

        def append_segment(scope:, eval_run_id:, segment:, lease:)
          scope, id = ids!(scope, eval_run_id)
          record = Store::Records.segment!(segment, id)
          append(:append_segment, scope, id, lease, record)
        end

        def append_trial(scope:, eval_run_id:, line:, lease:)
          scope, id = ids!(scope, eval_run_id)
          record = Store::Records.trial!(line, id)
          append(:append_trial, scope, id, lease, record)
        end

        def each_segment(scope:, eval_run_id:, &) = each_line(:each_segment, :segment, *ids!(scope, eval_run_id), &)
        def each_trial(scope:, eval_run_id:, &) = each_line(:each_trial, :trial, *ids!(scope, eval_run_id), &)

        def write_summary(scope:, eval_run_id:, summary:, lease:)
          scope, id = ids!(scope, eval_run_id)
          record = Store::Records.summary!(summary, scope, id)
          summarize(:write_summary, scope, id, lease, record)
        end

        def read_summary(scope:, eval_run_id:) = document(:read_summary, *ids!(scope, eval_run_id), "summary.json")

        def list_records(scope:, limit: Store::Listing::DEFAULT_LIMIT, after: nil)
          scope = Store::Records.scope!(scope)
          limit = Store::Listing.limit!(limit)
          cursor = Store::Listing.after!(after)
          guarded(:list_records) do
            entries, unreadable = @runs.entries(scope)
            Store::Listing.listing(entries, limit:, after: cursor, unreadable:) { @runs.status(scope, _1) }
          end
        end

        def request_cancel(scope:, actor:, reason:, eval_run_id: nil, tuning_run_id: nil)
          scope = Store::Records.scope!(scope)
          id = Store::TuningRecords.run_id!(eval_run_id, tuning_run_id)
          record = Store::Records.cancel!(actor, reason, @clock.call)
          guarded(:request_cancel) do
            run = @runs.recorded!(scope, id)
            created = Documents.create(@paths, run, ::File.join(run, "cancel.json"), record.text)
            created == :created ? :requested : :exists
          end
        end

        def cancel_request(scope:, eval_run_id: nil, tuning_run_id: nil)
          id = Store::TuningRecords.run_id!(eval_run_id, tuning_run_id)
          document(:cancel_request, Store::Records.scope!(scope), id, "cancel.json")
        end

        private

        def ids!(scope, eval_run_id) = [Store::Records.scope!(scope), Store::Records.eval_run_id!(eval_run_id)]

        def create(operation, scope, record)
          guarded(operation) do
            run = @runs.made!(scope, record.key)
            Documents.sweep(@paths, run)
            Documents.create(@paths, run, ::File.join(run, "header.json"), record.text)
          end
        end

        def summarize(operation, scope, id, lease, record)
          guarded(operation) { @writes.summarize(@runs.recorded!(scope, id), id, lease, record) }
        end

        # Fills in the operation of a StoreError raised below and, unless the
        # block yields to a caller's own code, turns any other I/O failure
        # into one.
        def guarded(operation, io: true)
          yield
        rescue StoreError => e
          raise e if e.operation

          raise StoreError.new(e.message, operation:)
        rescue SystemCallError, IOError => e
          raise unless io

          raise StoreError.new("#{operation} failed (#{e.class.name})", operation:)
        end

        def append(operation, scope, id, lease, record)
          name = Lines::FILES.fetch(APPENDS.fetch(operation))
          guarded(operation) { @writes.append(@runs.recorded!(scope, id), id, lease, name, record) }
        end

        def document(operation, scope, id, name) = guarded(operation) { @runs.document(scope, id, name) }

        def each_line(operation, kind, scope, id, &block)
          return enum_for(operation, scope:, **Store::TuningRecords.run_key(id)) unless block

          guarded(operation, io: false) { @runs.lines(scope, id, Lines::FILES[kind], &block) }
          nil
        end
      end
    end
  end
end

require_relative "file/paths"
require_relative "file/documents"
require_relative "file/lines"
require_relative "file/runs"
require_relative "file/writes"
