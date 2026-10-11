# frozen_string_literal: true

require_relative "errors"
require_relative "diagnostic_text"

module Smith
  # An agent's response that cannot be its step's output: cut off at its
  # output limit (OutputTruncated), refused (OutputRefused), or not the
  # structured output the agent declares (OutputInvalid). The response was
  # billed all the same. Not an AgentError and not retryable: the agent's
  # own retry, fallback and repairs have run, and running the same request
  # again would repeat the cost. Its failure family is `output_failure`;
  # details are bounded and persist with a failed step, so a restored run
  # raises the same error.
  class OutputFailure < Error
    DETAIL_NAMES = %i[agent_name model_used stop_reason problems].freeze
    DETAIL_KEYS = DETAIL_NAMES.to_h { |name| [name.to_s.freeze, name] }.freeze
    MAX_TEXT_BYTES = 256
    MAX_PROBLEMS = 20
    private_constant :DETAIL_NAMES, :DETAIL_KEYS

    attr_reader :agent_name, :model_used, :stop_reason, :problems

    # `message` is the persisted one when the error is restored.
    def initialize(agent_name:, model_used:, stop_reason: nil, problems: [], message: nil)
      @agent_name = agent_name
      @model_used = model_used
      @stop_reason = stop_reason
      @problems = Array(problems).first(MAX_PROBLEMS).map { |problem| self.class.bounded(problem.to_s) }.freeze
      super(message || describe)
    end

    def details
      texts = %i[agent_name model_used stop_reason].to_h { |name| [name, text_detail(public_send(name))] }
      texts.merge(problems:).freeze
    end

    class << self
      # Each output failure class's name and its restore from persisted
      # details, for the failure record validator and reconstructor.
      def restorers
        [OutputFailure, OutputTruncated, OutputRefused, OutputInvalid].to_h do |error_class|
          [error_class.name, ->(details, message = nil) { error_class.from_details(details, message:) }]
        end.freeze
      end

      def from_details(details, message: nil)
        values = normalize_details(details)
        new(agent_name: values.fetch(:agent_name)&.to_sym, model_used: values.fetch(:model_used),
            stop_reason: values.fetch(:stop_reason), problems: values.fetch(:problems), message:)
      end

      def bounded(text) = DiagnosticText.capture(text, max_bytes: MAX_TEXT_BYTES)

      private

      def normalize_details(details)
        raise ArgumentError, "output failure details must be a Hash" unless details.is_a?(Hash)

        values = {}
        Hash.instance_method(:each_pair).bind_call(details) do |key, value|
          name = detail_name(key, values)
          values[name] = name == :problems ? problem_list(value) : bounded_text(name, value)
        end
        raise ArgumentError, "output failure details are incomplete" unless values.length == DETAIL_NAMES.length

        values
      end

      def detail_name(key, seen)
        name = key.is_a?(Symbol) ? key : DETAIL_KEYS[key]
        raise ArgumentError, "output failure details contain an unknown attribute" unless DETAIL_NAMES.include?(name)
        raise ArgumentError, "output failure details contain a duplicate attribute" if seen.key?(name)

        name
      end

      def bounded_text(name, value)
        return value if value.nil?
        return value if value.is_a?(String) && value.valid_encoding? && value.bytesize <= MAX_TEXT_BYTES

        raise ArgumentError, "output failure detail #{name} must be bounded text"
      end

      def problem_list(value)
        unless value.is_a?(Array) && value.length <= MAX_PROBLEMS
          raise ArgumentError, "output failure problems must be a list of at most #{MAX_PROBLEMS}"
        end

        value.map { |problem| bounded_text(:problems, problem) }
      end
    end

    private

    def text_detail(value) = value && self.class.bounded(value.to_s)

    def outcome = "could not be used"

    def describe
      [
        "agent#{" :#{agent_name}" if agent_name} response#{" from model #{model_used}" if model_used} #{outcome}",
        (" (stop reason #{stop_reason})" if stop_reason),
        (": #{problems.first(3).join("; ")}" unless problems.empty?)
      ].join
    end
  end

  # The response stopped at its output limit.
  class OutputTruncated < OutputFailure
    private

    def outcome = "was cut off at its output limit"
  end

  # The provider or model declined to answer.
  class OutputRefused < OutputFailure
    private

    def outcome = "was refused"
  end

  # The output is not a JSON object, or breaks the agent's output contract
  # or a schema constraint Smith checks itself.
  class OutputInvalid < OutputFailure
    private

    def outcome = "is invalid"
  end
end
