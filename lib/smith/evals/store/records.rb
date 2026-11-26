# frozen_string_literal: true

require "json"
require_relative "../../scope"
require_relative "../actor"
require_relative "../identity"
require_relative "../../json_value"
require_relative "json_check"
require_relative "clock"

module Smith
  module Evals
    module Store
      # Internal. What Smith's stores check before they keep a record, and the
      # text they keep, so both read back the same way. A record is a JSON
      # object (JSONCheck). The kept text, at most MAX_BYTES, is a line's
      # compact JSON, or the indented JSON a header, summary or cancel flag is
      # kept as (the published examples' form). It is read back strictly, and
      # every field is checked on that read-back, the record as it will be
      # kept, never on the caller's object: a Hash whose default answers a
      # read its JSON does not hold is refused, so no write leaves a record
      # its store cannot read or list. Only the fields a store reads are
      # checked: the format, the run id and scope, the id within its kind, and
      # what a listing shows (a tuning run's: TuningRecords). The same record
      # is the same canonical JSON (RFC 8785), so a retry whose text another
      # json version wrote, or whose keys come in another order, is the record
      # already kept; a record with no canonical JSON (an integer past
      # 2**53 - 1, or more than 1,000,000 values) is refused.
      # O(N + sum k log k) in the record's size and its objects' keys.
      module Records
        MAX_BYTES = 8 * 1024 * 1024
        EVAL_RUN_ID = Identity::EVAL_RUN_ID
        TRIAL_ID = /\Atr_[0-9a-f]{32}\z/
        # UTC with up to microseconds, as the record schemas have it.
        TIMESTAMP = /\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,6}))?Z\z/
        STATUSES = %w[succeeded failed cancelled incomplete].freeze
        MAX_REASON_CHARACTERS = 1024
        FORMATS = { header: "smith.evals.record_header", segment: "smith.evals.segment",
                    trial: "smith.evals.trial", summary: "smith.evals.summary" }.freeze
        NAMES = { header: "a header", segment: "a launch line", trial: "a trial line", summary: "a summary",
                  cancel: "a cancel request", tuning_line: "a tuning line" }.freeze

        # value: the record as it reads back (frozen); text: what a store
        # keeps; key: its id among its kind (a header's is its eval run id),
        # nil for a cancel flag; digest: its identity (JSONCheck.identity).
        Record = Data.define(:value, :text, :key, :digest)

        module_function

        def scope!(scope) = Smith::Scope.build(scope)

        def eval_run_id!(id)
          return id if id.is_a?(String) && EVAL_RUN_ID.match?(id)

          raise ArgumentError, "an eval run id is er_ and 32 lowercase hex digits"
        end

        # A header, filed by its own id under its own scope.
        def header!(header, scope) = kept(header, :header) { header_fields!(_1, scope) }

        def segment!(segment, eval_run_id)
          kept(segment, :segment) do |value|
            line!(value, :segment, eval_run_id)
            positive!(value["segment"], "a launch line's segment")
          end
        end

        def trial!(line, eval_run_id)
          kept(line, :trial) do |value|
            line!(value, :trial, eval_run_id)
            unless value["trial_id"].is_a?(String) && TRIAL_ID.match?(value["trial_id"])
              raise ArgumentError, "a trial line's trial_id is tr_ and 32 lowercase hex digits"
            end

            [value["trial_id"], positive!(value["trial_revision"], "a trial line's trial_revision")]
          end
        end

        def summary!(summary, scope, eval_run_id) = kept(summary, :summary) { summary_fields!(_1, scope, eval_run_id) }

        # A stored header's fields, as a write and a listing read them; its
        # eval run id.
        def header_fields!(value, scope)
          format!(value, :header)
          id = eval_run_id!(value["eval_run_id"])
          raise ArgumentError, "the header's scope is not the scope it is stored under" if scope_of(value) != scope
          unless value["created_at"].is_a?(String) && TIMESTAMP.match?(value["created_at"])
            raise ArgumentError, "the header's created_at is a UTC time such as 2026-11-21T07:30:03.725Z"
          end
          raise ArgumentError, "the header's suite.name is a suite name" unless suite_name?(value["suite"])

          id
        end

        # A stored summary's fields, as a write and a listing read them; its
        # revision.
        def summary_fields!(value, scope, eval_run_id)
          line!(value, :summary, eval_run_id)
          raise ArgumentError, "the summary's scope is not the scope it is stored under" if scope_of(value) != scope
          unless STATUSES.include?(value["status"])
            raise ArgumentError, "the summary's status is one of #{STATUSES.join(", ")}"
          end

          positive!(value["summary_revision"], "a summary's summary_revision")
        end

        # The cancel flag: who asked, why (at most 1,024 characters, or nil)
        # and when, by the store's clock.
        def cancel!(actor, reason, time)
          actor = Actor.from_h(actor) unless actor.is_a?(Actor)
          raise ArgumentError, "a cancel request names its actor" if actor.nil?

          kept({ "actor" => actor.to_h, "reason" => reason!(reason), "at" => Clock.timestamp(time) }, :cancel) { nil }
        end

        def reason!(reason)
          return if reason.nil?
          unless JSONValue.utf8?(reason) && reason.length <= MAX_REASON_CHARACTERS
            raise ArgumentError, "a cancel reason is nil or at most #{MAX_REASON_CHARACTERS} characters of UTF-8"
          end

          reason.dup.force_encoding(Encoding::UTF_8)
        end

        # A record's text as read back: a frozen Hash, or ArgumentError
        # naming the problem, never the text.
        def read(text)
          JSONValue.parse!(text).tap { raise ArgumentError, "not a JSON object" unless _1.is_a?(Hash) }
        end

        # The indented form, with empty lists and objects written [] and {}
        # under every json version (before 2.8 they span lines).
        def document_text(value)
          "#{JSON.pretty_generate(value).gsub(/\[\n\s*\]/, "[]").gsub(/\{\n\s*\}/, "{}")}\n"
        end

        # The record as it will be kept: its text, read back, and the key the
        # block gives from that read-back, which every field check reads.
        def kept(record, kind)
          what = NAMES[kind]
          raise ArgumentError, "#{what} is a Hash" unless record.is_a?(Hash)

          JSONCheck.check!(record, what)
          text = %i[trial segment tuning_line].include?(kind) ? JSON.generate(record) : document_text(record)
          raise ArgumentError, "#{what} is over #{MAX_BYTES} bytes of JSON" if text.bytesize > MAX_BYTES

          value = read(text)
          Record.new(value:, text: text.freeze, key: yield(value), digest: JSONCheck.identity(value, what))
        end

        def line!(value, kind, eval_run_id)
          format!(value, kind)
          return if value["eval_run_id"] == eval_run_id

          raise ArgumentError, "#{NAMES[kind]}'s eval_run_id is not #{eval_run_id}"
        end

        def format!(value, kind)
          value["format"] == FORMATS[kind] || raise(ArgumentError, "#{NAMES[kind]}'s format is #{FORMATS[kind]}")
        end

        def positive!(value, what)
          return value if value.is_a?(Integer) && value.positive?

          raise ArgumentError, "#{what} is a positive Integer"
        end

        def scope_of(record)
          Smith::Scope.build(record["scope"])
        rescue Smith::ScopeInvalid
          nil
        end

        def suite_name?(suite)
          suite.is_a?(Hash) && suite["name"].is_a?(String) && Identity::NAME.match?(suite["name"])
        end
      end
    end
  end
end
