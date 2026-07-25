# frozen_string_literal: true

require "dry-struct"

require_relative "../types"

module Smith
  class Tool < RubyLLM::Tool
    class ExecutionBatchSourceMetadata < Dry::Struct
      MAX_NAME_BYTES = 256
      MAX_METADATA_BYTES = ArgumentSnapshot::MAX_BYTES

      MODULE_MATCH = Module.instance_method(:===)
      STRING_BYTESIZE = String.instance_method(:bytesize)
      STRING_VALID_ENCODING = String.instance_method(:valid_encoding?)
      SYMBOL_TO_S = Symbol.instance_method(:to_s)
      private_constant :MODULE_MATCH, :STRING_BYTESIZE, :STRING_VALID_ENCODING, :SYMBOL_TO_S

      Name = Types.Instance(String) | Types.Instance(Symbol)
      private_constant :Name

      attribute :key, Types::Any
      attribute :tool_call, Types::Any
      attribute :tool_call_id, Types::String.optional
      attribute :name, Name
      attribute :canonical_name, Types::String.constrained(min_size: 1)
      attribute :thought_signature, Types::String.optional
      attribute :metadata_byte_count, Types::Integer.constrained(gteq: 1)

      def self.capture(key:, tool_call:)
        name, canonical_name = owned_name(tool_call.name)
        tool_call_id = owned_id(tool_call)
        thought_signature = owned_thought_signature(tool_call)
        new(
          key:,
          tool_call:,
          tool_call_id:,
          name:,
          canonical_name:,
          thought_signature:,
          metadata_byte_count: string_bytes(canonical_name) + string_bytes(tool_call_id) +
                               string_bytes(thought_signature)
        )
      end

      def initialize(...)
        super
        freeze
      end

      def to_source_call
        ExecutionBatchSourceCall.new(
          **to_h,
          arguments: tool_call.arguments
        )
      end

      def self.owned_id(tool_call)
        return unless tool_call.respond_to?(:id)

        value = tool_call.id
        value && owned_string(value, "tool call id")
      end
      private_class_method :owned_id

      def self.owned_thought_signature(tool_call)
        return unless tool_call.respond_to?(:thought_signature)

        value = tool_call.thought_signature
        value && owned_string(value, "tool call thought signature")
      end
      private_class_method :owned_thought_signature

      def self.owned_name(value)
        raise Error, "tool call name must be a string or symbol" unless string?(value) || symbol?(value)

        source = symbol?(value) ? SYMBOL_TO_S.bind_call(value) : value
        canonical = owned_string(source, "tool call name", max_bytes: MAX_NAME_BYTES)
        raise Error, "tool call name must be a bounded non-empty value" if canonical.empty?

        [symbol?(value) ? canonical.to_sym : canonical, canonical]
      end
      private_class_method :owned_name

      def self.owned_string(value, label, max_bytes: MAX_METADATA_BYTES)
        raise Error, "#{label} must be a string" unless string?(value)
        raise Error, "#{label} must contain valid encoded text" unless STRING_VALID_ENCODING.bind_call(value)
        raise Error, "#{label} exceeds #{max_bytes} bytes" if STRING_BYTESIZE.bind_call(value) > max_bytes

        normalized = String.new(value).encode(Encoding::UTF_8)
        raise Error, "#{label} exceeds #{max_bytes} bytes" if STRING_BYTESIZE.bind_call(normalized) > max_bytes

        normalized.freeze
      rescue EncodingError
        raise Error, "#{label} must contain valid UTF-8 text"
      end

      def self.string_bytes(value) = value ? STRING_BYTESIZE.bind_call(value) : 0

      def self.string?(value) = MODULE_MATCH.bind_call(String, value)

      def self.symbol?(value) = MODULE_MATCH.bind_call(Symbol, value)

      private_class_method :owned_string, :string_bytes, :string?, :symbol?
    end
  end
end
