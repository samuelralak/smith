# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class ExecutionBatchRegistry
      PENDING_BATCH = Object.new.freeze
      private_constant :PENDING_BATCH

      def initialize
        @batches = {}.compare_by_identity
        @builder = ExecutionBatchBuilder.new
        @mutex = Mutex.new
      end

      def build_and_register(tool_calls:, tools:, context:, admission_resolver:)
        captured_calls = ExecutionBatchCollection.capture(tool_calls)
        entries = captured_calls.each_pair.map { |key, tool_call| [key, tool_call].freeze }.freeze
        source_calls = entries.map(&:last).freeze
        reserve_calls!(source_calls)
        call_admissions = admission_resolver.call(source_calls)
        batch = @builder.call(entries:, tools:, context:, call_admissions:)
        publish_batch!(source_calls, batch)
        batch
      rescue Exception # rubocop:disable Lint/RescueException
        rollback_registration(source_calls, batch)
        raise
      end

      def unregister(batch)
        return unless batch

        @mutex.synchronize do
          unregister_calls(batch.source_calls, batch)
          unregister_calls(batch.tool_calls.each_value, batch)
        end
      end

      def fetch(tool_call)
        @mutex.synchronize do
          batch = @batches[tool_call]
          raise Error, "tool call batch registration is incomplete" if batch.equal?(PENDING_BATCH)

          batch
        end
      end

      private

      def reserve_calls!(calls)
        @mutex.synchronize do
          validate_inactive_calls!(calls)
          calls.each { @batches[_1] = PENDING_BATCH }
        end
      end

      def publish_batch!(calls, batch)
        @mutex.synchronize do
          unless calls.all? { @batches[_1].equal?(PENDING_BATCH) }
            raise Error, "tool call batch registration changed before publication"
          end

          calls.each { @batches[_1] = batch }
          batch.tool_calls.each_value { @batches[_1] = batch }
        end
      end

      def unregister_calls(calls, batch)
        calls.each { @batches.delete(_1) if @batches[_1].equal?(batch) }
      end

      def release_calls!(calls)
        return unless calls

        @mutex.synchronize do
          calls.each { @batches.delete(_1) if @batches[_1].equal?(PENDING_BATCH) }
        end
      end

      def rollback_registration(source_calls, batch)
        Thread.handle_interrupt(Exception => :never) do
          batch&.settle!
        ensure
          unregister(batch)
          release_calls!(source_calls)
        end
      end

      def validate_inactive_calls!(calls)
        seen = {}.compare_by_identity
        calls.each do |tool_call|
          raise Error, "tool call appears more than once in one provider batch" if seen.key?(tool_call)
          raise Error, "tool call is already active on this chat" if @batches.key?(tool_call)

          seen[tool_call] = true
        end
      end
    end
  end
end
