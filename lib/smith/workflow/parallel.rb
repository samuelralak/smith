# frozen_string_literal: true

require "concurrent"

require_relative "parallel/cancellation_signal"

module Smith
  class Workflow
    class Parallel
      def self.resolve_branch_count(transition, context)
        count = transition.agent_opts[:count]
        resolved = count.respond_to?(:call) ? count.call(context) : (count || 1)
        return resolved if resolved.is_a?(Integer) && resolved.positive?

        raise WorkflowError, "parallel branch count must be a positive integer"
      end

      def self.execute(branches:)
        signal = CancellationSignal.new

        futures = branches.map do |branch|
          Concurrent::Promises.future(branch, signal) do |b, s|
            b.call(s)
          rescue StandardError
            s.cancel!
            raise
          end
        end

        fulfilled, values, reasons = Concurrent::Promises.zip(*futures).result

        unless fulfilled
          error = preferred_error(reasons)
          raise error
        end

        values
      end

      def self.preferred_error(reasons)
        errors = reasons.compact
        errors.find { |error| !error.is_a?(Cancellation) } || errors.first
      end
    end
  end
end
