# frozen_string_literal: true

require_relative "diagnostic_text"
require_relative "error"

module Smith
  class ProviderPermanentFailure < Error
    DETAIL_NAMES = %i[provider model_id source_error_class].freeze
    DETAIL_KEYS = DETAIL_NAMES.to_h { |name| [name.to_s.freeze, name] }.freeze
    MAX_DETAIL_BYTES = 512
    private_constant :DETAIL_NAMES, :DETAIL_KEYS, :MAX_DETAIL_BYTES

    attr_reader :provider, :model_id, :source_error_class

    def initialize(message, provider:, model_id:, source_error_class:)
      @provider = provider&.to_sym
      @model_id = model_id.to_s.dup.freeze
      @source_error_class = source_error_class.to_s.dup.freeze
      super(message)
    end

    def details
      {
        provider: provider && DiagnosticText.capture(provider.to_s, max_bytes: MAX_DETAIL_BYTES),
        model_id: DiagnosticText.capture(model_id, max_bytes: MAX_DETAIL_BYTES),
        source_error_class: DiagnosticText.capture(source_error_class, max_bytes: MAX_DETAIL_BYTES)
      }.freeze
    end

    def self.from_details(details, message: nil)
      new(message, **normalize_details(details))
    end

    def self.normalize_details(details)
      raise ArgumentError, "provider failure details must be a Hash" unless details.is_a?(Hash)

      values = {}
      Hash.instance_method(:each_pair).bind_call(details) do |key, value|
        name = key.is_a?(Symbol) ? key : DETAIL_KEYS[key]
        raise ArgumentError, "provider failure details contain an unknown attribute" unless DETAIL_NAMES.include?(name)
        raise ArgumentError, "provider failure details contain a duplicate attribute" if values.key?(name)

        values[name] = bounded_detail(name, value)
      end
      raise ArgumentError, "provider failure details are incomplete" unless values.length == DETAIL_NAMES.length

      values
    end

    def self.bounded_detail(name, value)
      return value if name == :provider && value.nil?

      bounded = value.is_a?(String) && value.valid_encoding? && value.bytesize <= MAX_DETAIL_BYTES
      raise ArgumentError, "provider failure detail #{name} must be bounded text" unless bounded

      value
    end
    private_class_method :normalize_details, :bounded_detail
  end
end
