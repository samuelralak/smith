# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class BoundedCompletionGuard
      def initialize
        @state = nil
        @state_mutex = Mutex.new
        @owner = nil
        @depth = 0
        @owner_mutex = Mutex.new
        @admissions = nil
      end

      def around_completion(owner, reentrant:, &block)
        Thread.handle_interrupt(Object => :never) do
          enter(owner, reentrant:)
          begin
            Thread.handle_interrupt(Object => :immediate, &block)
          ensure
            leave(owner)
          end
        end
      end

      def state_for(allowance)
        @state_mutex.synchronize do
          return @state if @state&.allowance.equal?(allowance)

          @state = BoundedCompletionState.new(allowance: allowance)
        end
      end

      def with_admitted_calls(tool_calls, tools:, allowance:, ledger:, &block)
        Thread.handle_interrupt(Object => :never) do
          reservation = allowance.reserve_batch(tool_calls.each_value.map(&:name), ledger:)
          return false unless reservation

          previous = @admissions
          @admissions = build_admissions(tool_calls, tools, reservation)
          begin
            Thread.handle_interrupt(Object => :immediate, &block)
          ensure
            begin
              reservation.settle!
            ensure
              @admissions = previous
            end
          end
          true
        end
      end

      def admission_for(tool_call)
        @admissions&.fetch(tool_call, nil)
      end

      def admissions_for(tool_calls)
        tool_calls.each_with_object({}.compare_by_identity) do |tool_call, admissions|
          admission = admission_for(tool_call)
          admissions[tool_call] = admission if admission
        end.freeze
      end

      private

      def build_admissions(tool_calls, tools, reservation)
        tool_calls.each_value.with_object({}.compare_by_identity) do |tool_call, admissions|
          tool = tools[tool_call.name.to_sym]
          next unless tool

          admissions[tool_call] = CallAdmission.new(tool:, reservation:)
        end
      end

      def enter(owner, reentrant:)
        @owner_mutex.synchronize do
          if @owner && (@owner != owner || !reentrant)
            raise Error, "concurrent or reentrant completion on one bounded Smith chat is unsupported"
          end

          # Each outer completion derives fresh budget policy state, so a
          # finalized earlier ask can never leak its terminal state into a
          # later independently bounded completion on the same chat.
          @state_mutex.synchronize { @state = nil } if @depth.zero?
          @owner = owner
          @depth += 1
        end
      end

      def leave(owner)
        @owner_mutex.synchronize do
          return unless @owner == owner

          @depth -= 1
          @owner = nil if @depth.zero?
        end
      end
    end
  end
end
