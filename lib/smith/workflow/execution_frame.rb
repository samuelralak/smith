# frozen_string_literal: true

require "logger"

module Smith
  class Workflow
    # Absorbs the five-flag bookkeeping pattern (claimed, result_obtained,
    # recorded, intentional_retry, finalize_succeeded) duplicated across
    # host Execution wrappers. The host yields its per-attempt work in,
    # records lifecycle milestones via mark_*! setters, and the frame's
    # ensure invokes on_clear / always_ensure based on the canonical
    # decision: claimed && (finalize_succeeded || (intentional_retry &&
    # recorded) || !result_obtained).
    #
    # OrderingError and AlreadyRun inherit from Smith::Error (NOT
    # Smith::WorkflowError) so host `rescue Smith::WorkflowError` blocks
    # cannot silently downgrade ordering bugs to handler-error states.
    class ExecutionFrame
      class OrderingError < Smith::Error; end
      class AlreadyRun < Smith::Error; end

      def self.run(workflow: nil, on_clear: nil, always_ensure: nil, logger: nil)
        new(workflow: workflow, on_clear: on_clear, always_ensure: always_ensure, logger: logger).run { |frame| yield frame }
      end

      def initialize(workflow: nil, on_clear: nil, always_ensure: nil, logger: nil)
        @workflow = workflow
        @on_clear = on_clear
        @always_ensure = always_ensure
        @logger = logger
        @claimed = false
        @claimed_set = false
        @result_obtained = false
        @recorded = false
        @intentional_retry = false
        @finalize_succeeded = false
        @run_invoked = false
        @finished = false
      end

      def run
        raise AlreadyRun, "ExecutionFrame already run" if @run_invoked

        @run_invoked = true
        result = yield(self)
        result
      ensure
        finish!
      end

      def mark_claimed!(value = true)
        if @claimed_set && @claimed != value
          raise OrderingError, "mark_claimed! called twice with conflicting values (#{@claimed.inspect} then #{value.inspect})"
        end

        @claimed = value
        @claimed_set = true
        value
      end

      def mark_result_obtained!
        raise OrderingError, "mark_result_obtained! requires prior mark_claimed!(true)" unless @claimed == true

        @result_obtained = true
      end

      def mark_recorded!
        raise OrderingError, "mark_recorded! requires prior mark_result_obtained!" unless @result_obtained

        @recorded = true
      end

      def mark_intentional_retry!(value = true)
        if @claimed_set && @claimed == false
          raise OrderingError, "mark_intentional_retry! invalid after mark_claimed!(false)"
        end

        @intentional_retry = value
      end

      def mark_finalize_succeeded!
        raise OrderingError, "mark_finalize_succeeded! requires prior mark_recorded!" unless @recorded

        @finalize_succeeded = true
      end

      def claimed?
        @claimed == true
      end

      def result_obtained?
        @result_obtained
      end

      def recorded?
        @recorded
      end

      def intentional_retry?
        @intentional_retry
      end

      def finalize_succeeded?
        @finalize_succeeded
      end

      def should_clear?
        claimed? && (@finalize_succeeded || (@intentional_retry && @recorded) || !@result_obtained)
      end

      def finish!
        return false if @finished

        @finished = true
        cleared = false

        if should_clear?
          cleared = invoke_on_clear
        end

        invoke_always_ensure if claimed?

        cleared
      end

      private

      def invoke_on_clear
        if @on_clear.respond_to?(:call)
          @on_clear.call
          return true
        end

        target = resolve_workflow
        if target.nil?
          resolved_logger.warn("Smith::Workflow::ExecutionFrame: workflow resolver returned nil; skipping clear")
          return false
        end

        target.clear_persisted!
        true
      rescue StandardError => e
        resolved_logger.error("Smith::Workflow::ExecutionFrame on_clear raised: #{e.class}: #{e.message}")
        true
      end

      def invoke_always_ensure
        return unless @always_ensure.respond_to?(:call)

        @always_ensure.call
      rescue StandardError => e
        resolved_logger.error("Smith::Workflow::ExecutionFrame always_ensure raised: #{e.class}: #{e.message}")
      end

      def resolve_workflow
        return @workflow.call if @workflow.respond_to?(:call)

        @workflow
      end

      def resolved_logger
        @logger || Smith.config.logger || (@_fallback_logger ||= Logger.new($stderr))
      end
    end
  end
end
