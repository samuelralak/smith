# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Tool < RubyLLM::Tool
    class ExecutionBatch
      extend Dry::Initializer

      option :context
      option :tool_calls
      option :source_calls
      option :dispatch_calls
      option :source_calls_by_dispatch
      option :requests
      option :targets
      option :call_admissions, default: proc { {}.compare_by_identity.freeze }
      option :call_reservation, optional: true

      attr_reader :capture_failures, :fatal_failures, :notification_failures, :terminal_failures

      def initialize(...)
        super
        @state = ExecutionBatchState.new(requests:)
        @mutex = Mutex.new
        initialize_failure_queues
        @host_admitted = false
        @host_admission_required = context.fetch(:current_invocation_batch_admitter) && requests.any?
      end

      def request_for(tool_call) = requests[tool_call]

      def target_for(tool_call) = targets[tool_call]

      def admission_for(tool_call) = call_admissions[tool_call]

      def dispatch_for(tool_call) = requests.key?(tool_call) ? tool_call : dispatch_calls[tool_call]

      def source_for(tool_call) = source_calls_by_dispatch[tool_call]

      def claim_dispatch!(tool_call) = @state.claim_dispatch!(tool_call)

      def verify_dispatch!(tool_call, current_tool:, claim:)
        request = requests.fetch(tool_call)
        target = targets.fetch(tool_call)
        return if dispatch_admitted? &&
                  @state.dispatch_claimed?(tool_call, claim) &&
                  target_unchanged?(current_tool, target, request) &&
                  call_unchanged?(tool_call, request)

        raise ToolDispatchRejected, "admitted tool invocation changed before dispatch"
      end

      def mark_started!(tool_call, claim:) = @state.mark_started!(tool_call, claim:)

      def mark_executed!(tool_call, claim:) = @state.mark_executed!(tool_call, claim:)

      def started?(tool_call) = @state.started?(tool_call)

      def mark_host_admitted!
        @mutex.synchronize { @host_admitted = true }
      end

      def host_admitted?
        @mutex.synchronize { @host_admitted }
      end

      def claim_failure_request(tool_call) = @state.claim_failure_request(tool_call)

      def claim_unsettled_request = @state.claim_unsettled_request

      def complete_failure_notification!(tool_call) = @state.complete_failure_notification!(tool_call)

      def release_failure_notification!(tool_call, state) = @state.release_failure_notification!(tool_call, state)

      def settle! = call_reservation&.settle!

      private

      def initialize_failure_queues
        @capture_failures = Queue.new
        @fatal_failures = Queue.new
        @notification_failures = Queue.new
        @terminal_failures = Queue.new
      end

      def dispatch_admitted? = !@host_admission_required || host_admitted?

      def target_unchanged?(current_tool, target, request)
        current_tool.equal?(target) && current_tool.instance_of?(request.tool_class)
      end

      def call_unchanged?(tool_call, request)
        tool_call.id.equal?(request.invocation.tool_call_id) &&
          tool_call.name.to_s == request.invocation.tool_name &&
          tool_call.arguments.equal?(request.arguments)
      end
    end
  end
end
