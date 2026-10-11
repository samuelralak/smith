# frozen_string_literal: true

module Smith
  module Testing
    # The checks behind the assertions and matchers: each returns nil when
    # it holds, else what failed.
    module Checks
      module_function

      def waiting_for(workflow, event = nil, kind: nil)
        wait = workflow.awaiting
        return "expected the run to wait, but it is #{workflow.state} and not waiting" unless wait
        return other_event(event, wait) if event && wait.event.to_s != event.to_s

        "expected a #{kind} wait, but the run's is a #{wait.kind} wait" if kind && wait.kind.to_s != kind.to_s
      end

      def other_event(event, wait)
        "expected the run to wait for #{event}, but it waits for #{wait.event || "a #{wait.kind}"}"
      end

      def transitioned_through(workflow, names)
        taken = Testing.transitions(workflow)
        rest = taken
        names.each do |name|
          index = rest.index(name.to_sym)
          return "expected the run through #{names.inspect} in order; it went through #{taken.inspect}" unless index

          rest = rest.drop(index + 1)
        end
        nil
      end

      def usage_recorded(workflow, count: nil, **attributes)
        attributes = usage_attributes(attributes)
        entries = workflow.usage_entries
        found = entries.count { |entry| attributes.all? { |name, value| same?(entry.public_send(name), value) } }
        return if count ? found == count : found.positive?

        "expected #{count || "a"} usage entry matching #{attributes.inspect}, found #{found} among " \
          "#{entries.map { _1.to_h.slice(:agent_name, :input_tokens, :output_tokens, :mode) }.inspect}"
      end

      # UsageEntry attributes; an agent class stands for its registered name.
      def usage_attributes(attributes)
        unknown = attributes.keys - Workflow::UsageEntry.members
        raise ArgumentError, "unknown usage attributes: #{unknown.join(", ")}" unless unknown.empty?

        agent = attributes[:agent_name]
        agent.is_a?(Class) ? attributes.merge(agent_name: agent.register_as) : attributes
      end

      def same?(actual, expected)
        actual == expected || ((expected.is_a?(Symbol) || expected.is_a?(String)) && actual.to_s == expected.to_s)
      end
    end
  end
end
