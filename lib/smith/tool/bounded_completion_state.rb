# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Tool < RubyLLM::Tool
    class BoundedCompletionState
      extend Dry::Initializer

      option :allowance

      def initialize(...)
        super
        @state = :open
        @continuation_required = false
        @mutex = Mutex.new
      end

      def request_continuation!
        @mutex.synchronize { @continuation_required = true }
      end

      def consume_continuation!
        @mutex.synchronize do
          required = @continuation_required
          @continuation_required = false
          required
        end
      end

      def request_finalization!
        @mutex.synchronize { @state = :required if @state == :open }
      end

      def begin_finalization
        @mutex.synchronize do
          return :active if @state == :finalizing

          @state = :finalizing
          :started
        end
      end

      def abort_finalization!
        @mutex.synchronize { @state = :required if @state == :finalizing }
      end

      def finalization_required?
        @mutex.synchronize { @state == :required }
      end

      def finalization_started?
        @mutex.synchronize { @state == :finalizing }
      end
    end
  end
end
