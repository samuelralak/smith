# frozen_string_literal: true

require_relative "streaming/session"
require_relative "streaming/json_field"

module Smith
  # A step declared with `execute Agent, stream: :name` sends its reply's
  # text, as the model writes it, to a sink the host gives it. The host
  # registers a callable under that name in `Smith.config.stream_sinks`;
  # when the step starts, Smith calls it with the step's info (the stream's
  # name, the run's execution key, the transition) and streams to the sink
  # it returns, or does not stream the step when it returns nil (nobody is
  # listening). Each step execution gets its own sink, so concurrent runs
  # never share one.
  #
  # The sink is told of each provider call (`start(info)`), each text chunk
  # (`delta(text)`), text Smith discards (`reset(reason)`), the step's
  # accepted output (`finish(output)`) and its failure (`fail(error_class)`);
  # Smith calls only the methods the sink defines. See Session. The text is
  # the model's, before the step's guardrails and output checks run: a
  # draft until `finish`.
  #
  # Streaming changes nothing durable: the step's output, usage, budgets,
  # guardrails, contracts and persistence are those of the same step
  # without it, and a replayed step streams again.
  module Streaming
    def self.check_sinks!(sinks)
      raise ArgumentError, "Smith.config.stream_sinks must be a Hash of sink names to sinks" unless sinks.is_a?(Hash)

      sinks.to_h { |name, sink| [checked_name!(name), checked_sink!(name, sink)] }.freeze
    end

    def self.checked_name!(name)
      return name.to_sym if (name.is_a?(Symbol) || name.is_a?(String)) && !name.to_s.empty?

      raise ArgumentError, "Smith.config.stream_sinks names must be Symbols or Strings, got #{name.inspect}"
    end

    def self.checked_sink!(name, sink)
      return sink if sink.respond_to?(:call)

      raise ArgumentError, "stream sink #{name.inspect} must be a callable that takes the step's info and returns " \
                           "the step's sink (or nil)"
    end
    private_class_method :checked_name!, :checked_sink!

    # The step's Session, or nil when its sink is nil (or the callable
    # raised, which is logged). StreamSinkMissing when the name is not
    # registered.
    def self.open(name, execution_key:, transition:)
      factory = Smith.config.stream_sinks.fetch(name) { raise StreamSinkMissing, name }
      info = { stream: name, execution_key:, transition: }.freeze
      sink = begin
        factory.call(info)
      rescue StandardError => e
        Smith.config.logger&.error("Smith stream sink #{name.inspect} call error: #{e.class}")
        nil
      end
      sink && Session.new(sink, info)
    end
  end
end
