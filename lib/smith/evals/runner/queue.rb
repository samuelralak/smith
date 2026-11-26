# frozen_string_literal: true

module Smith
  module Evals
    class Runner
      # Internal. The trials a launch has left (slice-1a design, 5.7), in
      # plan order, each with a not-before time once it waits for a retry:
      # a worker takes the first one due, or waits on the condition variable
      # until the earliest is due or a running trial puts one back. Once
      # halted (a cancel, a run-stopping error), no trial starts: a trial
      # waiting for its retry is handed out at once, to be recorded as it
      # stands, and the rest stay unrun. The first halt's stop stands. O(Q)
      # per take for Q waiting trials, under one Mutex.
      class Queue
        # position: in plan order; tried: the attempts so far, nil before the
        # first; not_before: monotonic seconds, nil when due.
        Item = Data.define(:position, :index, :sample, :tried, :not_before)

        attr_reader :stop

        def initialize(items)
          @items = items.sort_by(&:position)
          @running = 0
          @stop = nil
          @lock = Mutex.new
          @changed = ConditionVariable.new
        end

        # The next trial to work on, or nil when none is left to start.
        def take
          @lock.synchronize do
            loop do
              item = due
              return started(item) if item
              return if @items.none? { started?(_1) } && (@stop || @running.zero?)

              @changed.wait(@lock, wait)
            end
          end
        end

        # A trial back for a retry once `not_before` has passed.
        def put_back(item)
          @lock.synchronize do
            @running -= 1
            @items.insert(@items.index { _1.position > item.position } || @items.size, item)
            @changed.broadcast
          end
        end

        def done
          @lock.synchronize do
            @running -= 1
            @changed.broadcast
          end
        end

        # Stops trials from starting; the first stop given stands.
        def halt(stop)
          @lock.synchronize do
            @stop ||= stop
            @changed.broadcast
          end
        end

        def halted? = @lock.synchronize { !@stop.nil? }

        private

        def due
          return @items.find { started?(_1) } if @stop

          now = clock
          @items.find { _1.not_before.nil? || _1.not_before <= now }
        end

        def started(item)
          @items.delete(item)
          @running += 1
          item
        end

        def started?(item) = !item.tried.nil?

        # Until the earliest not-before, or a change.
        def wait
          times = @items.filter_map(&:not_before)
          times.empty? ? nil : [times.min - clock, 0].max
        end

        def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
