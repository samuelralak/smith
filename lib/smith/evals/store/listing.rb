# frozen_string_literal: true

require_relative "records"

module Smith
  module Evals
    module Store
      # Internal. One order for every store's listing: newest first by the
      # header's created_at read as a time (so "07:30:03Z" is before
      # "07:30:03.5Z"), then by eval run id, highest first. The cursor names
      # the last record a page gave, so a page after it never repeats or skips
      # one, while records created later appear only where they fall in the
      # order. O(R log R) for R records in the scope.
      module Listing
        DEFAULT_LIMIT = 50
        MAX_LIMIT = 1_000
        CURSOR = /\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z),(er_[0-9a-f]{32})\z/

        module_function

        def limit!(limit)
          return limit if limit.is_a?(Integer) && limit.between?(1, MAX_LIMIT)

          raise ArgumentError, "limit is an Integer from 1 to #{MAX_LIMIT}"
        end

        # The cursor's place in the order, or nil for the first page.
        def after!(after)
          return if after.nil?

          match = CURSOR.match(after) if after.is_a?(String)
          raise ArgumentError, "after is a cursor list_records gave as next" unless match

          [order_key(match[1]), match[2]]
        end

        # A listing entry from a stored header, without its status.
        def entry(header)
          { "eval_run_id" => header["eval_run_id"], "suite" => header.dig("suite", "name"),
            "created_at" => header["created_at"] }
        end

        # A run a listing could not read, and why (a path within the root
        # and the problem, never the record's content).
        def unreadable(eval_run_id, problem) = { "eval_run_id" => eval_run_id, "problem" => problem }.freeze

        # The listing: the page after the cursor, newest first, each entry
        # with the status the block gives for its eval run id (read only for
        # the page), and the cursor for the next page, nil when none is left.
        # A run that does not read is left out and named in "unreadable",
        # once in a walk: one whose header does not read (given, as it has no
        # place in the order) on the first page, one whose status does not
        # (the block gives an unreadable entry) on its page.
        def listing(entries, limit:, after:, unreadable: [])
          page, following = page(entries, limit:, after:)
          named = after ? [] : unreadable.dup
          records = page.filter_map do |entry|
            status = yield(entry["eval_run_id"])
            next entry.merge("status" => status).freeze if status.is_a?(String)

            named << status
            nil
          end
          { "records" => records.freeze, "next" => following,
            "unreadable" => named.sort_by { _1["eval_run_id"] }.freeze }.freeze
        end

        def page(entries, limit:, after:)
          ordered = entries.sort_by { order(_1) }.reverse
          ordered = ordered.drop_while { (order(_1) <=> after) >= 0 } if after
          page = ordered.first(limit)
          [page, ("#{page.last["created_at"]},#{page.last["eval_run_id"]}" if ordered.size > limit)]
        end

        def order(entry) = [order_key(entry["created_at"]), entry["eval_run_id"]]

        # The time with its fraction written to six digits, so text order is
        # time order.
        def order_key(created_at)
          match = Records::TIMESTAMP.match(created_at)
          "#{match[1]}.#{(match[2] || "").ljust(6, "0")}"
        end
      end
    end
  end
end
