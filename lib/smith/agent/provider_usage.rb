# frozen_string_literal: true

require "dry-struct"

require_relative "../types"
require_relative "../providers/response_facts"

module Smith
  class Agent
    # The usage one provider response reported. `input_tokens` counts only
    # uncached input, which is how RubyLLM reports every provider: tokens read
    # from or written to a prompt cache are `cache_read_tokens` and
    # `cache_write_tokens`. `thinking_tokens` are already inside
    # `output_tokens` and are reported, never added. The optional counts are
    # nil when the provider did not report them.
    class ProviderUsage < Dry::Struct
      COUNT_READERS = {
        cache_read_tokens: %i[cache_read_tokens cached_tokens],
        cache_write_tokens: %i[cache_write_tokens cache_creation_tokens],
        thinking_tokens: %i[thinking_tokens]
      }.freeze
      OPTIONAL_COUNTS = COUNT_READERS.keys.freeze

      attribute :input_tokens, Types::Integer
      attribute :output_tokens, Types::Integer
      attribute :cache_read_tokens, Types::Integer.optional.default(nil)
      attribute :cache_write_tokens, Types::Integer.optional.default(nil)
      attribute :thinking_tokens, Types::Integer.optional.default(nil)
      attribute :stop_reason, Types::String.optional.default(nil)
      attribute :provider_message_id, Types::String.optional.default(nil)
      # How the response was made: :stream, :batch, or nil (synchronous).
      attribute :mode, Types::Symbol.optional.default(nil)

      def self.from_message(message)
        return unless message.respond_to?(:input_tokens) && message.respond_to?(:output_tokens)

        input_tokens = message.input_tokens
        output_tokens = message.output_tokens
        return unless input_tokens.is_a?(Integer) && output_tokens.is_a?(Integer)

        new(input_tokens:, output_tokens:, **optional_counts(message), **Providers::ResponseFacts.from_message(message))
      end

      def self.optional_counts(message)
        COUNT_READERS.transform_values do |readers|
          readers.lazy.filter_map { |reader| count_from(message, reader) }.first
        end
      end

      def self.count_from(message, reader)
        return unless message.respond_to?(reader)

        value = message.public_send(reader)
        value if value.is_a?(Integer) && value >= 0
      end

      # The stop reason and message id are those of the last response, the
      # one that ended the attempt.
      def self.sum(usages)
        return if usages.empty?

        counts = OPTIONAL_COUNTS.to_h do |name|
          values = usages.filter_map(&name)
          [name, values.empty? ? nil : values.sum]
        end
        new(input_tokens: usages.sum(&:input_tokens), output_tokens: usages.sum(&:output_tokens), **counts,
            stop_reason: usages.last.stop_reason, provider_message_id: usages.last.provider_message_id,
            mode: usages.last.mode)
      end
      private_class_method :optional_counts, :count_from

      # This usage with the stop reason and message id of `facts`, a
      # ResponseFacts result, in place of its own: a tool loop's summed
      # usage carries its final response's facts even when that response
      # reported no usage.
      def with_response_facts(facts)
        self.class.new(**to_h.except(:stop_reason, :provider_message_id), **facts)
      end

      # This usage as a streamed response's, with the facts its stream
      # carried (Providers::StreamFacts).
      def streamed(facts) = with_response_facts(facts).new(mode: :stream)

      # Optional members are omitted when nil, so usage without cache or
      # response details keeps its earlier shape.
      def to_h
        super.compact
      end
      alias to_hash to_h

      # Every input token the provider processed, cached or not.
      def total_input_tokens
        input_tokens + (cache_read_tokens || 0) + (cache_write_tokens || 0)
      end

      def total_tokens
        total_input_tokens + output_tokens
      end
    end
  end
end
