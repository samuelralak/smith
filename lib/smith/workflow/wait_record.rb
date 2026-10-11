# frozen_string_literal: true

require "time"

module Smith
  class Workflow
    # The persisted form of a run's wait: a frozen Hash of Strings, so it
    # round-trips through JSON unchanged. Built on entry, checked on
    # restore against the workflow class, and read as a Wait.
    module WaitRecord
      FIELDS = %w[kind event token transition into entered_at deadline_at].freeze
      TOKEN = /\A[0-9a-f]{64}\z/

      module_function

      def build(transition, token, seconds, now)
        config = transition.await_config
        {
          "kind" => config.fetch(:kind).to_s, "event" => config[:event]&.to_s, "token" => token,
          "transition" => transition.name.to_s, "into" => config[:into]&.to_s,
          "entered_at" => now.iso8601(6), "deadline_at" => (now + seconds).iso8601(6)
        }.freeze
      end

      # A wait's timeout in seconds: the declared number, or what its
      # callable returns for the context, which must be positive.
      def seconds(timeout, context)
        seconds = timeout.respond_to?(:call) ? timeout.call(context) : timeout
        return seconds if (seconds.is_a?(Integer) || (seconds.is_a?(Float) && seconds.finite?)) && seconds.positive?

        raise WorkflowError, "a wait's timeout must be a positive number of seconds"
      end

      def to_wait(record, transition)
        Wait.new(
          kind: record.fetch("kind").to_sym, event: record["event"], token: record.fetch("token"),
          transition: transition.name, into: record["into"]&.to_sym,
          entered_at: Time.iso8601(record.fetch("entered_at")), deadline_at: Time.iso8601(record.fetch("deadline_at"))
        )
      end

      # A persisted wait, checked: a malformed one raises SerializationError,
      # and one whose transition the class no longer declares as that kind
      # of wait is refused like any unknown position.
      def restore(value, workflow_class:, persistence_key:)
        return if value.nil?

        record = stringified(value)
        raise Smith::SerializationError, "persisted workflow awaiting is malformed" unless well_formed?(record)

        transition = workflow_class.transition_named(record["transition"])
        return record.slice(*FIELDS).freeze if declared_wait?(transition, record)

        raise Smith::UnknownTransitionOnRestore.new(workflow: workflow_class.name, persistence_key:,
                                                    transition: record["transition"].to_sym)
      end

      def stringified(value)
        raise Smith::SerializationError, "persisted workflow awaiting is malformed" unless value.is_a?(Hash)

        value.to_h { |key, field| [key.to_s, field.is_a?(Symbol) ? field.to_s : field] }
      end

      def well_formed?(record)
        %w[await delay].include?(record["kind"]) && TOKEN.match?(record["token"].to_s) &&
          nonempty_string?(record["transition"]) && await_fields?(record) &&
          %w[entered_at deadline_at].all? { |field| time?(record[field]) }
      end

      def await_fields?(record)
        await = record["kind"] == "await"
        %w[event into].all? { |field| await ? nonempty_string?(record[field]) : record[field].nil? }
      end

      def declared_wait?(transition, record)
        transition&.awaits? && transition.await_config.fetch(:kind).to_s == record["kind"]
      end

      def nonempty_string?(value) = value.is_a?(String) && !value.empty?

      def time?(value)
        value.is_a?(String) && !Time.iso8601(value).nil?
      rescue ArgumentError
        false
      end
    end
  end
end
