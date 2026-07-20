# frozen_string_literal: true

require "digest"

require_relative "error"

module Smith
  class ToolCaptureFailed < Error
    REASONS = %i[
      collector_missing collector_invalid capture_empty capture_block_failed collector_failed
    ].freeze
    REASONS_BY_NAME = REASONS.to_h { |reason| [reason.to_s.freeze, reason] }.freeze
    DETAIL_NAMES = %i[tool_name reason].freeze
    DETAIL_KEYS = DETAIL_NAMES.to_h { |name| [name.to_s.freeze, name] }.freeze
    MAX_TOOL_NAME_BYTES = 256
    private_constant :REASONS, :REASONS_BY_NAME, :DETAIL_NAMES, :DETAIL_KEYS, :MAX_TOOL_NAME_BYTES

    attr_reader :tool_name, :reason

    def initialize(tool_name:, reason:)
      @tool_name = normalize_tool_name(tool_name)
      @reason = normalize_reason(reason)
      super("strict result capture failed for #{@tool_name}: #{@reason}")
    end

    def details
      { tool_name:, reason: }.freeze
    end

    def self.from_details(details)
      values = normalize_details(details)
      new(tool_name: values.fetch(:tool_name), reason: values.fetch(:reason))
    end

    def self.for_runtime(tool_name:, reason:)
      new(tool_name:, reason:)
    rescue ArgumentError
      new(tool_name: diagnostic_tool_name(tool_name), reason:)
    end

    def self.normalize_details(details)
      raise ArgumentError, "tool capture failure details must be a Hash" unless details.is_a?(Hash)

      values = {}
      Hash.instance_method(:each_pair).bind_call(details) do |key, value|
        name = normalize_detail_name(key)
        unless DETAIL_NAMES.include?(name)
          raise ArgumentError, "tool capture failure details contain an unknown attribute"
        end
        raise ArgumentError, "tool capture failure details contain a duplicate attribute" if values.key?(name)

        values[name] = value
      end
      missing = DETAIL_NAMES - values.keys
      raise ArgumentError, "tool capture failure details are missing required attributes" if missing.any?

      values
    end

    def self.normalize_detail_name(key)
      return key if key.is_a?(Symbol)

      DETAIL_KEYS[key] if key.is_a?(String)
    end

    def self.diagnostic_tool_name(value)
      bytes = value.to_s.b
      return "anonymous_tool" if bytes.empty?

      "tool_#{Digest::SHA256.hexdigest(bytes)}"
    end
    private_class_method :normalize_details, :normalize_detail_name, :diagnostic_tool_name

    private

    def normalize_tool_name(value)
      unless value.is_a?(String) || value.is_a?(Symbol)
        raise ArgumentError, "tool capture failure tool name must be a String or Symbol"
      end

      name = value.to_s
      raise ArgumentError, "tool capture failure tool name must be valid UTF-8" unless name.valid_encoding?

      name = name.encode(Encoding::UTF_8)
      raise ArgumentError, "tool capture failure tool name must be valid UTF-8" unless name.valid_encoding?

      unless name.bytesize.between?(1, MAX_TOOL_NAME_BYTES)
        raise ArgumentError, "tool capture failure tool name must be a bounded non-empty value"
      end

      name.dup.freeze
    rescue EncodingError
      raise ArgumentError, "tool capture failure tool name must be valid UTF-8"
    end

    def normalize_reason(value)
      unless value.is_a?(String) || value.is_a?(Symbol)
        raise ArgumentError, "tool capture failure reason must be a String or Symbol"
      end

      REASONS_BY_NAME.fetch(value.to_s) do
        raise ArgumentError, "tool capture failure reason is not recognized"
      end
    end
  end
end
