# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Tool < RubyLLM::Tool
    class ExecutionBatchState
      SETTLED_STATES = %i[executed failure_notified failure_notifying].freeze
      private_constant :SETTLED_STATES

      extend Dry::Initializer

      option :requests

      def initialize(...)
        super
        @states = requests.each_key.to_h { [_1, :pending] }.compare_by_identity
        @dispatch_claims = {}.compare_by_identity
        @notification_attempted = {}.compare_by_identity
        @unsettled_tool_calls = requests.each_key.to_a.freeze
        @unsettled_index = 0
        @mutex = Mutex.new
      end

      def claim_dispatch!(tool_call)
        @mutex.synchronize do
          unless @states[tool_call] == :pending
            raise ToolDispatchRejected, "admitted tool invocation was already claimed"
          end

          claim = Object.new.freeze
          @dispatch_claims[tool_call] = claim
          @states[tool_call] = :claimed
          claim
        end
      end

      def dispatch_claimed?(tool_call, claim)
        @mutex.synchronize do
          @dispatch_claims[tool_call].equal?(claim) && %i[claimed started].include?(@states[tool_call])
        end
      end

      def mark_started!(tool_call, claim:) = transition_dispatch!(tool_call, claim, from: :claimed, to: :started)

      def mark_executed!(tool_call, claim:) = transition_dispatch!(tool_call, claim, from: :started, to: :executed)

      def started?(tool_call) = @mutex.synchronize { %i[started executed].include?(@states[tool_call]) }

      def claim_failure_request(tool_call)
        @mutex.synchronize do
          state = @states[tool_call]
          return if state.nil? || SETTLED_STATES.include?(state) || @notification_attempted.key?(tool_call)

          claim_notification!(tool_call)
          [requests.fetch(tool_call), state]
        end
      end

      def claim_unsettled_request
        @mutex.synchronize do
          while @unsettled_index < @unsettled_tool_calls.length
            tool_call = next_unsettled_tool_call
            state = @states[tool_call]
            next if SETTLED_STATES.include?(state) || @notification_attempted.key?(tool_call)

            claim_notification!(tool_call)
            return [tool_call, requests.fetch(tool_call), state]
          end
          nil
        end
      end

      def complete_failure_notification!(tool_call)
        @mutex.synchronize do
          @states[tool_call] = :failure_notified if @states[tool_call] == :failure_notifying
        end
      end

      def release_failure_notification!(tool_call, state)
        @mutex.synchronize do
          @states[tool_call] = state if @states[tool_call] == :failure_notifying
        end
      end

      private

      def next_unsettled_tool_call
        tool_call = @unsettled_tool_calls[@unsettled_index]
        @unsettled_index += 1
        tool_call
      end

      def claim_notification!(tool_call)
        @notification_attempted[tool_call] = true
        @states[tool_call] = :failure_notifying
      end

      def transition_dispatch!(tool_call, claim, from:, to:)
        @mutex.synchronize do
          unless @dispatch_claims[tool_call].equal?(claim) && @states[tool_call] == from
            raise ToolDispatchRejected, "admitted tool invocation has an invalid dispatch state"
          end

          @states[tool_call] = to
        end
      end
    end
  end
end
