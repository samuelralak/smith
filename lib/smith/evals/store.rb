# frozen_string_literal: true

require_relative "errors"
require_relative "store/lease"
require_relative "store/records"
require_relative "store/listing"

module Smith
  module Evals
    # Experimental; the methods below are frozen with slice 1a.3, and later
    # slices add methods beside them (slice-1a design, 9.1). The eval store
    # keeps each eval run's record: a header written once, a launch line per
    # launch, a trial line per trial result, a summary replaced whole, and a
    # cancel flag. It is the resume ledger, so a store write is durable when
    # it returns.
    #
    #   create_record(scope:, header:)                         # => :created, or :exists (never clobbered)
    #   read_header(scope:, eval_run_id:)                      # => Hash or nil
    #   acquire_lease(scope:, eval_run_id:)                    # => a lease (#release); RunBusy while one is held
    #   append_segment(scope:, eval_run_id:, segment:, lease:) # => :appended, or :exists (the same line)
    #   append_trial(scope:, eval_run_id:, line:, lease:)      # => :appended, or :exists (the same line)
    #   each_segment(scope:, eval_run_id:)                     # => Enumerator, append order, lines there as it begins
    #   each_trial(scope:, eval_run_id:)                       # => the same; a torn last line skipped
    #   write_summary(scope:, eval_run_id:, summary:, lease:)  # => :written, or :exists (the same summary)
    #   read_summary(scope:, eval_run_id:)                     # => Hash or nil
    #   list_records(scope:, limit: 50, after: nil)            # => {"records", "next" (cursor or nil), "unreadable"}
    #   request_cancel(scope:, eval_run_id:, actor:, reason:)  # => :requested, or :exists (the first one stands)
    #   cancel_request(scope:, eval_run_id:)                   # => nil or {"actor", "reason", "at"}
    #
    # The contract every store keeps, a host's own (a database, say) as
    # Smith::Evals::Stores::Memory and Smith::Evals::Stores::File do; the
    # return values above are part of it:
    #
    # - Every call takes a Smith::Scope, and one scope never sees another's
    #   records.
    # - Values read are plain Hashes with String keys, deeply frozen, equal
    #   byte for byte to what was first written. A record is one JSON object
    #   (Store::Records) with a canonical JSON (RFC 8785).
    # - The same record is the same canonical JSON, so a retry written by
    #   another json version, or with its keys in another order, is :exists
    #   and changes nothing. A different record under an id the run holds (a
    #   trial id and revision, a launch number, the stored summary revision,
    #   or a summary revision not above it) raises ArgumentError.
    # - Every write but the header and the cancel flag needs the run's live
    #   lease; a second lease raises RunBusy. A lease belongs to the process
    #   that took it: in the file store a forked child may not write under
    #   it; the memory store lives in one process, so there the rule holds
    #   within it (a forked child writes only to its own copy).
    # - A read of a run's lines yields those there when it begins, never one
    #   appended during it.
    # - Listing is newest first, by created_at read as a time, then by eval
    #   run id, highest first; "next" is a cursor for the page after it, nil
    #   when none is left, and limit is 1 to 1,000. A run that does not read
    #   is left out and named, with its problem, in "unreadable", once in a
    #   walk, so one bad record never breaks a scope's listing; the key is
    #   part of the frozen return value (a store that holds none gives []).
    module Store
      METHODS = %i[create_record read_header acquire_lease append_segment append_trial each_segment each_trial
                   write_summary read_summary list_records request_cancel cancel_request].freeze

      # Whether an object answers every method of the interface.
      def self.store?(object) = METHODS.all? { object.respond_to?(_1) }
    end
  end
end
