# frozen_string_literal: true

module Smith
  class Workflow
    class Parallel
      CancellationSignal = Struct.new(:cancelled, :mutex) do
        def initialize
          super(false, Mutex.new)
        end

        def cancel!
          mutex.synchronize { self.cancelled = true }
        end

        def cancelled?
          mutex.synchronize { cancelled }
        end
      end
    end
  end
end
