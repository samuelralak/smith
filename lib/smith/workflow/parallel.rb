# frozen_string_literal: true

require_relative "../errors"
require_relative "../tool_capture_failed"
require_relative "parallel/cancellation"
require_relative "parallel/cancellation_signal"
require_relative "parallel/execution_context"
require_relative "parallel/nested_execution"
require_relative "parallel/root_execution"

module Smith
  class Workflow
    class Parallel
      def self.resolve_branch_count(transition, context)
        count = transition.agent_opts[:count]
        resolved = count.respond_to?(:call) ? count.call(context) : (count || 1)
        validate_branch_count!(resolved)
      end

      def self.validate_branch_count!(count)
        unless count.is_a?(Integer) && count.positive?
          raise WorkflowError, "parallel branch count must be a positive integer"
        end

        limit = Smith.config.parallel_branch_limit
        raise WorkflowError, "parallel branch count exceeds configured limit #{limit}" if count > limit

        count
      end

      def self.execute(branches:)
        validate_branch_count!(branches.length)
        context = ExecutionContext.current
        return NestedExecution.new(branches:, context:).call if context

        RootExecution.new(branches:).call
      end

      def self.preferred_error(reasons)
        errors = Array(reasons).compact
        process_fatal_error(errors) ||
          notification_failure(errors) ||
          terminal_execution_error(errors) ||
          ordinary_error(errors) ||
          errors.first
      end

      def self.process_fatal_error(errors) = errors.find { !_1.is_a?(StandardError) }

      def self.notification_failure(errors) = errors.find { _1.is_a?(ToolFailureNotificationFailed) }

      def self.terminal_execution_error(errors) = errors.find { Smith::Errors.retry_forbidden?(_1) }

      def self.ordinary_error(errors) = errors.find { !_1.is_a?(Cancellation) }

      private_class_method :process_fatal_error, :notification_failure, :terminal_execution_error, :ordinary_error
    end
  end
end
