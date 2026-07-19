# frozen_string_literal: true

module Smith
  class Workflow
    class Parallel
      class CancellationSignal
        def initialize
          @cancelled = false
          @reason = nil
          @mutex = Mutex.new
        end

        def cancel!(error = nil)
          @mutex.synchronize do
            @reason ||= error
            @cancelled = true
          end
        end

        def cancelled?
          @mutex.synchronize { @cancelled }
        end

        def reason
          @mutex.synchronize { @reason }
        end
      end
    end
  end
end
