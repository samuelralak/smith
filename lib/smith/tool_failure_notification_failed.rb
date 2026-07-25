# frozen_string_literal: true

require_relative "error"
require_relative "diagnostic_text"

module Smith
  class ToolFailureNotificationFailed < Error
    DETAIL_NAMES = %i[
      dispatch_error_class dispatch_error_message notification_error_class notification_error_message
    ].freeze
    DETAIL_KEYS = DETAIL_NAMES.to_h { |name| [name.to_s.freeze, name] }.freeze
    EXCEPTION_MESSAGE = Exception.instance_method(:message)
    MODULE_NAME = Module.instance_method(:name)
    OBJECT_CLASS = Object.instance_method(:class)
    private_constant :DETAIL_NAMES, :DETAIL_KEYS, :EXCEPTION_MESSAGE, :MODULE_NAME, :OBJECT_CLASS

    attr_reader :details, :dispatch_error, :notification_error

    def initialize(dispatch_error:, notification_error:)
      @dispatch_error = dispatch_error
      @notification_error = notification_error
      @details = build_details
      super(
        "host failed to record a terminal tool outcome: " \
        "#{@details.fetch(:notification_error_class)}: #{@details.fetch(:notification_error_message)}"
      )
    end

    def build_details
      {
        dispatch_error_class: DiagnosticText.capture(error_class_name(dispatch_error), max_bytes: 512),
        dispatch_error_message: DiagnosticText.capture(error_message(dispatch_error)),
        notification_error_class: DiagnosticText.capture(error_class_name(notification_error), max_bytes: 512),
        notification_error_message: DiagnosticText.capture(error_message(notification_error))
      }.freeze
    end
    private :build_details

    def self.from_details(details)
      values = normalize_details(details)
      new(
        dispatch_error: restored_error(values, :dispatch_error),
        notification_error: restored_error(values, :notification_error)
      )
    end

    def self.normalize_details(details)
      raise ArgumentError, "tool failure notification details must be a Hash" unless details.is_a?(Hash)

      values = details.each_with_object({}) do |(key, value), normalized|
        append_detail!(normalized, key, value)
      end
      validate_complete!(values)
      values.freeze
    end

    def self.append_detail!(normalized, key, value)
      name = normalize_detail_name(key)
      raise ArgumentError, "tool failure notification details contain an unknown attribute" unless name
      raise ArgumentError, "tool failure notification details contain a duplicate attribute" if normalized.key?(name)
      raise ArgumentError, "tool failure notification detail values must be strings" unless value.is_a?(String)

      normalized[name] = value
    end

    def self.validate_complete!(values)
      missing = DETAIL_NAMES - values.keys
      raise ArgumentError, "tool failure notification details are missing required attributes" if missing.any?
    end

    def self.normalize_detail_name(key)
      return key if key.is_a?(Symbol) && DETAIL_NAMES.include?(key)

      DETAIL_KEYS[key] if key.is_a?(String)
    end

    def self.restored_error(values, prefix)
      RuntimeError.new(
        "#{values.fetch(:"#{prefix}_class")}: #{values.fetch(:"#{prefix}_message")}"
      )
    end

    def error_class_name(error)
      error_class = OBJECT_CLASS.bind_call(error)
      MODULE_NAME.bind_call(error_class) || MODULE_NAME.bind_call(error_class.superclass) || "StandardError"
    end

    def error_message(error) = EXCEPTION_MESSAGE.bind_call(error)
    private :error_class_name, :error_message

    private_class_method :normalize_details, :append_detail!, :validate_complete!, :normalize_detail_name,
                         :restored_error
  end
end
