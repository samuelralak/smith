# frozen_string_literal: true

module CoreInvisibility
  # Everything one scenario left in the sinks the harness watches, in the
  # order it arrived. Thread-safe: branch threads write too.
  class Record
    SINKS = %i[requests memo batches states persisted artifacts usage_entries traces events stream ledger logs errors
               results].freeze
    def initialize
      @lock = Mutex.new
      @sinks = SINKS.to_h { [_1, []] }
      @counts = Hooks::COUNTED.to_h { |owner, name| [Hooks.label(owner, name), 0] }
    end

    def add(sink, value)
      plain = Normal.value(value)
      @lock.synchronize { @sinks.fetch(sink) << plain }
      nil
    end

    def count(name) = @lock.synchronize { @counts[name] += 1 }

    # A run's saved state after a step, or at the end of a host call. The
    # seconds its steps ran are measured on the monotonic clock, so they
    # read "s", as trace durations read "ms".
    def state(workflow) = add(:states, Record.steady_state(workflow.to_state))

    def self.steady_state(state)
      state[:active_seconds].is_a?(Numeric) ? state.merge(active_seconds: "s") : state
    end

    def persisted(entry) = add(:persisted, entry.map { Record.steady_item(_1) })

    # A payload, or the payloads among a write's keyword arguments.
    def self.steady_item(item)
      case item
      when String then steady(item)
      when Hash then item.transform_values { _1.is_a?(String) ? steady(_1) : _1 }
      else item
      end
    end

    # A payload as written, its measured seconds replaced.
    def self.steady(payload) = payload.gsub(/"active_seconds":[-+0-9.eE]+/, '"active_seconds":"s"')

    def error(error) = add(:errors, error)

    def to_h(draws)
      @lock.synchronize do
        { "random_draws" => draws, "counts" => @counts.dup }.merge(@sinks.transform_keys(&:to_s))
      end
    end
  end
end
