# frozen_string_literal: true

module Smith
  module Evals
    module Store
      # Internal. A store's clock, a callable returning a Time (cancel
      # requests record it; the file store ages stray temporaries by it), and
      # the form records write a time in: UTC, to the millisecond.
      module Clock
        module_function

        def check!(clock)
          return clock if clock.respond_to?(:call)

          raise ArgumentError, "clock responds to call and returns a Time"
        end

        def timestamp(time)
          raise ArgumentError, "a store's clock returns a Time" unless time.is_a?(Time)

          time.getutc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
        end
      end
    end
  end
end
