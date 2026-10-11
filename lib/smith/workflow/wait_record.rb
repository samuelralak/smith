# frozen_string_literal: true

require "time"

module Smith
  class Workflow
    # The persisted form of a run's wait: a frozen Hash of frozen Strings, so
    # it round-trips through JSON unchanged and no caller can change it.
    # Built on entry, checked on restore against the workflow class and the
    # run's position, and read as a Wait.
    module WaitRecord
      FIELDS = %w[kind event token transition into entered_at deadline_at children].freeze
      TOKEN = /\A[0-9a-f]{64}\z/
      ZONED = /(?:Z|[+-]\d\d:\d\d)\z/

      module_function

      # `children` is how many runs a map or call launched; nil otherwise.
      def build(transition, token, seconds, now, children: nil)
        config = transition.await_config
        frozen(timing(transition, token, seconds, now).merge(
                 "kind" => config.fetch(:kind).to_s, "event" => config[:event]&.to_s, "into" => config[:into]&.to_s,
                 "children" => children
               ))
      end

      # A batch step's wait for the results of its `count` requests.
      def build_batch(transition, token, seconds, now, count)
        frozen(timing(transition, token, seconds, now)
          .merge("kind" => "batch", "event" => Batch::EVENT, "into" => nil, "children" => count))
      end

      # A durable retry's wait: no event or context key.
      def build_retry(transition, token, seconds, now)
        frozen(timing(transition, token, seconds, now)
          .merge("kind" => "retry", "event" => nil, "into" => nil, "children" => nil))
      end

      def timing(transition, token, seconds, now)
        { "token" => token, "transition" => transition.name.to_s, "entered_at" => now.utc.iso8601(6),
          "deadline_at" => (now + seconds).utc.iso8601(6) }
      end

      # A wait's timeout in seconds: the declared number, or what its
      # callable returns for the context, which must be positive.
      def seconds(timeout, context)
        seconds = timeout.respond_to?(:call) ? timeout.call(context) : timeout
        return seconds if (seconds.is_a?(Integer) || (seconds.is_a?(Float) && seconds.finite?)) && seconds.positive?

        raise WorkflowError, "a wait's timeout must be a positive number of seconds"
      end

      # The event and context key read as the transition declares them; a
      # retry's attempt and error read from the run's pending retry, a
      # batch's attempt from its pending batch.
      def to_wait(record, transition, pending_retry, pending_batch = nil)
        config = wait_config(record, transition)
        pending = { "retry" => pending_retry, "batch" => pending_batch }[record["kind"]]
        Wait.new(
          kind: config.fetch(:kind), event: config[:event], token: record.fetch("token"), transition: transition.name,
          into: config[:into], entered_at: Time.iso8601(record.fetch("entered_at")),
          deadline_at: Time.iso8601(record.fetch("deadline_at")), children: record["children"],
          attempt: pending&.fetch("attempt"), error: pending&.fetch("error", nil)
        )
      end

      def wait_config(record, transition)
        { "retry" => { kind: :retry }, "batch" => { kind: :batch, event: Batch::EVENT.to_sym } }
          .fetch(record["kind"]) { transition.await_config }
      end

      # A persisted wait, checked: a malformed one raises SerializationError,
      # and one the class no longer declares exactly (the transition, its
      # kind, event and context key) or that does not start from the run's
      # state is refused like any unknown position.
      def restore(value, workflow_class:, persistence_key:, state:, next_transition:)
        return if value.nil?

        record = stringified(value)
        unless well_formed?(record) && next_transition.nil?
          raise Smith::SerializationError, "persisted workflow awaiting is malformed"
        end

        transition = workflow_class.transition_named(record["transition"])
        return frozen(record.slice(*FIELDS)) if declared_wait?(transition, record, state)

        raise Smith::UnknownTransitionOnRestore.new(workflow: workflow_class.name, persistence_key:,
                                                    transition: record["transition"].to_sym)
      end

      def stringified(value)
        raise Smith::SerializationError, "persisted workflow awaiting is malformed" unless value.is_a?(Hash)

        value.to_h { |key, field| [key.to_s, field.is_a?(Symbol) ? field.to_s : field] }
      end

      def well_formed?(record)
        %w[await delay children retry batch].include?(record["kind"]) && TOKEN.match?(record["token"].to_s) &&
          nonempty_string?(record["transition"]) && await_fields?(record) && times?(record) && children_count?(record)
      end

      # A map's or call's wait holds how many children it launched, a
      # batch's how many requests it sent.
      def children_count?(record)
        count = record["children"]
        case record["kind"]
        when "batch" then count.is_a?(Integer) && count.between?(1, 10_000)
        when "children" then count.is_a?(Integer) && count.between?(0, 10_000)
        else count.nil?
        end
      end

      # An await or a map's wait for its children names its event and
      # context key; a batch its event alone; a delay or a retry neither.
      def await_fields?(record)
        event, into = record.values_at("event", "into")
        case record["kind"]
        when "batch" then event == Batch::EVENT && into.nil?
        when "delay", "retry" then event.nil? && into.nil?
        else nonempty_string?(event) && nonempty_string?(into)
        end
      end

      # Both times carry their zone, and the deadline is not before entry.
      def times?(record)
        entered, deadline = record.values_at("entered_at", "deadline_at")
        [entered, deadline].all? { |value| value.is_a?(String) && ZONED.match?(value) } &&
          Time.iso8601(entered) <= Time.iso8601(deadline)
      rescue ArgumentError
        false
      end

      def declared_wait?(transition, record, state)
        return false unless transition && [nil, state.to_s].include?(transition.from&.to_s)

        declared_kind?(transition, record)
      end

      def declared_kind?(transition, record)
        case record["kind"]
        when "retry" then transition.durable_retry?
        when "batch" then transition.batches? && record["children"] == batch_count(transition)
        else transition.awaits? && declared_fields(transition.await_config) == record.values_at("kind", "event", "into")
        end
      end

      def declared_fields(config) = [config.fetch(:kind), config[:event], config[:into]].map { _1&.to_s }

      def batch_count(transition) = transition.fanout? ? transition.fanout_config.fetch(:branches).length : 1

      def nonempty_string?(value) = value.is_a?(String) && !value.empty?

      def frozen(record) = record.transform_values { |value| value&.dup&.freeze }.freeze
    end
    private_constant :WaitRecord
  end
end
