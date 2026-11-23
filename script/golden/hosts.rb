# frozen_string_literal: true

require "digest"

module CoreInvisibility
  # The host objects a scenario hands Smith, each writing what it is given
  # to the current record.
  module Hosts
    # The memory persistence adapter, with every write and the keyword
    # arguments it came with (a `ttl:` Smith starts or stops passing shows).
    class Adapter < Smith::PersistenceAdapters::Memory
      def initialize = super(identity: "memory:golden")

      def store(key, payload, **options)
        CoreInvisibility.record.persisted(["store", key, options, payload])
        super
      end

      def store_versioned(key, payload, **options)
        CoreInvisibility.record.persisted(["store_versioned", key, options, payload])
        super
      end

      def replace_exact(key, payload, **options)
        CoreInvisibility.record.persisted(["replace_exact", key, options, payload])
        super
      end

      def delete(key)
        CoreInvisibility.record.persisted(["delete", key])
        super
      end

      def record_heartbeat(key, **options)
        CoreInvisibility.record.persisted(["heartbeat", key, options])
        super
      end
    end

    # The artifact store, with every call a run makes on it: each store's
    # bytes (their size and SHA-256), content type, run and the ref it
    # answers, and each fetch (what it found), ownership check, delete and
    # expiry listing. An extra or changed write shows, though refs are
    # content hashes.
    class Artifacts < Smith::Artifacts::Memory
      def self.facts(data)
        data.is_a?(String) ? { bytes: data.bytesize, sha256: Digest::SHA256.hexdigest(data) } : data
      end

      def store(data, content_type: "application/octet-stream", execution_namespace: nil)
        ref = super
        CoreInvisibility.record.add(:artifacts,
                                    ["store", Artifacts.facts(data), content_type, execution_namespace, ref])
        ref
      end

      def fetch(ref)
        data = super
        CoreInvisibility.record.add(:artifacts, ["fetch", ref, Artifacts.facts(data)])
        data
      end

      def stored_by?(ref, execution_namespace)
        super.tap { CoreInvisibility.record.add(:artifacts, ["stored_by?", ref, execution_namespace, _1]) }
      end

      def delete(ref, execution_namespace: nil)
        CoreInvisibility.record.add(:artifacts, ["delete", ref, execution_namespace])
        super
      end

      def expired(retention: nil, execution_namespace: nil)
        super.tap { CoreInvisibility.record.add(:artifacts, ["expired", retention, execution_namespace, _1]) }
      end
    end

    # A response memo, keyed as Smith keys it. With `crash_on` set to a
    # record's `complete` value, the process "dies" (a non-StandardError)
    # right after it stores that record, or the `crash_after`th such one.
    class Memo
      attr_accessor :crash_on, :crash_after

      def initialize
        @records = {}
        @matched = 0
      end

      def fetch(key)
        CoreInvisibility.record.add(:memo, ["fetch", key])
        @records[key]
      end

      def store(key, record)
        CoreInvisibility.record.add(:memo, ["store", key, record])
        @records[key] = record
        return unless crash_on && record["complete"] == crash_on

        @matched += 1
        return if @matched < (crash_after || 1)

        self.crash_on = nil
        raise Killed, "the process died after the memo stored"
      end
    end

    # What a killed process looks like to Smith: an exception it does not
    # rescue.
    class Killed < Exception; end # rubocop:disable Lint/InheritException

    # A batch queue: each request and its digest.
    class BatchQueue
      attr_reader :items

      def initialize = @items = []

      def enqueue(**request)
        @items << request
        CoreInvisibility.record.add(:batches, request.merge(digest: Smith::Batch.digest(request.fetch(:request))))
      end
    end

    # A host budget ledger; `admit` decides each reservation.
    class Ledger
      def initialize(admit: ->(_count) { true })
        @admit = admit
        @reserves = 0
        @lock = Mutex.new
      end

      def reserve!(amount, key:, expires_at:)
        count = @lock.synchronize { @reserves += 1 }
        CoreInvisibility.record.add(:ledger, ["reserve", key, amount, expires_at])
        @admit.call(count)
      end

      def reconcile!(key, amount) = CoreInvisibility.record.add(:ledger, ["reconcile", key, amount])
      def release!(key) = CoreInvisibility.record.add(:ledger, ["release", key])
    end

    # A stream sink; the callable that opens one is recorded with its info.
    class Sink
      def self.opener
        lambda do |info|
          CoreInvisibility.record.add(:stream, ["open", info])
          new
        end
      end

      %i[start delta reset finish fail].each do |name|
        define_method(name) { |*args| CoreInvisibility.record.add(:stream, [name.to_s, *args]) }
      end
    end

    # Records a run's saved state after each step it takes.
    module Stepped
      def advance!(...)
        result = super
        CoreInvisibility.record.state(self)
        result
      end
    end
  end
end
