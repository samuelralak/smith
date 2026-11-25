# frozen_string_literal: true

require_relative "../../store/records"
require_relative "../../store/listing"

module Smith
  module Evals
    module Stores
      class Memory
        # Internal. One run in a memory store: the texts it keeps, the ids
        # its lines hold, its listing entry and status, and its lease. The
        # store's Mutex guards every call.
        class Run
          attr_reader :entry, :header, :segments, :trials, :summary, :status, :cancel
          attr_accessor :lease

          def initialize(header)
            @entry = Store::Listing.entry(header.value)
            @header = header.text
            @segments = []
            @trials = []
            @held = {}
            @status = "running"
          end

          # The run, when this lease is its live one.
          def held!(lease, id)
            return self if lease.is_a?(Store::Lease) && @lease.equal?(lease) && !lease.released?

            raise ArgumentError, "a write to eval run #{id} needs its live lease from this store"
          end

          # Keeps a line once: the same record again is :exists, another under
          # its id is refused.
          def append(kind, record, id)
            known = @held[[kind, record.key]]
            return :exists if known == record.digest
            raise ArgumentError, "eval run #{id} already holds a different line with this id" if known

            @held[[kind, record.key]] = record.digest
            (kind == :trial ? @trials : @segments) << record.text
            :appended
          end

          # Only above the stored revision; the stored summary again is
          # :exists.
          def summarize(record)
            return :exists if @summary_digest == record.digest

            stored = @summary && Store::Records.read(@summary)["summary_revision"]
            if stored && record.key <= stored
              raise ArgumentError, "summary_revision #{record.key} is not above the stored #{stored}"
            end

            @summary = record.text
            @summary_digest = record.digest
            @status = record.value["status"]
            :written
          end

          # The first request stands.
          def request_cancel(record)
            return :exists if @cancel

            @cancel = record.text
            :requested
          end
        end
        private_constant :Run
      end
    end
  end
end
