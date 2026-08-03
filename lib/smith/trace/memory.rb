# frozen_string_literal: true

module Smith
  module Trace
    class Memory
      CONFIG_MAP = {
        transition: :trace_transitions,
        tool_call: :trace_tool_calls,
        token_usage: :trace_token_usage,
        provider_call: :trace_provider_calls,
        cost: :trace_cost,
        normalizer_decision: :trace_normalizer
      }.freeze

      CONTENT_KEYS = %i[content prompt response args result].freeze

      # Generous enough that test and development runs never hit it; a bound
      # exists at all so a long-lived process with parallel branches cannot
      # grow this adapter without limit.
      DEFAULT_LIMIT = 10_000

      attr_reader :traces, :limit

      def initialize(limit: DEFAULT_LIMIT)
        unless limit.is_a?(Integer) && limit.positive?
          raise ArgumentError, "Smith::Trace::Memory limit must be a positive integer, got #{limit.inspect}"
        end

        @limit = limit
        @traces = []
        @dropped_count = 0
        @mutex = Mutex.new
      end

      def record(type:, data:)
        return unless type_enabled?(type)

        entry = { type: type, data: filter_content(data) }
        @mutex.synchronize do
          if @traces.length >= @limit
            @dropped_count += 1
          else
            @traces << entry
          end
        end
      end

      # Entries rejected because the adapter was full. Zero in any healthy
      # test run; a growing value means the limit needs raising or the
      # process needs a clear!.
      def dropped_count
        @mutex.synchronize { @dropped_count }
      end

      # A consistent copy for readers that may race concurrent recording;
      # #traces stays the live array for compatibility.
      def snapshot
        @mutex.synchronize { @traces.dup }
      end

      def clear!
        @mutex.synchronize do
          @traces = []
          @dropped_count = 0
        end
      end

      private

      def type_enabled?(type)
        config_key = CONFIG_MAP[type]
        return true unless config_key

        Smith.config.send(config_key) != false
      end

      def filter_content(data)
        case Smith.config.trace_content
        when true
          data
        when :redacted
          data.transform_values { |v| v.is_a?(String) ? "[REDACTED]" : v }
        else
          data.except(*CONTENT_KEYS)
        end
      end
    end
  end
end
