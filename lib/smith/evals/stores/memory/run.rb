# frozen_string_literal: true

require_relative "../../store/records"
require_relative "../../store/tuning_records"
require_relative "../../store/listing"

module Smith
  module Evals
    module Stores
      class Memory
        # Internal. One run in a memory store, an eval run or a tuning run:
        # the texts it keeps, its lines by kind and the ids they hold, its
        # listing entry (nil for a tuning run) and status, and its lease. The
        # store's Mutex guards every call.
        class Run
          attr_reader :entry, :header, :summary, :status, :cancel
          attr_accessor :lease

          def initialize(header, entry)
            @entry = entry
            @header = header.text
            @lines = Hash.new { |lines, kind| lines[kind] = [] }
            @held = {}
            @status = "running"
          end

          # The texts of its lines of one kind, in append order.
          def lines(kind) = @lines[kind]

          # The run, when this lease is its live one.
          def held!(lease, id)
            return self if lease.is_a?(Store::Lease) && @lease.equal?(lease) && !lease.released?

            raise ArgumentError, "a write to #{named(id)} needs its live lease from this store"
          end

          # Keeps a line once: the same record again is :exists, another under
          # its id is refused.
          def append(kind, record, id)
            known = @held[[kind, record.key]]
            return :exists if known == record.digest
            raise ArgumentError, "#{named(id)} already holds a different line with this id" if known

            @held[[kind, record.key]] = record.digest
            @lines[kind] << record.text
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

          def named(id) = "#{Store::TuningRecords.run_name(id)} #{id}"

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
