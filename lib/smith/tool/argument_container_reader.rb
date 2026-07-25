# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Tool < RubyLLM::Tool
    class ArgumentContainerReader
      MODULE_MATCH = Module.instance_method(:===)
      ARRAY_LENGTH = Array.instance_method(:length)
      ARRAY_AREF = Array.instance_method(:[])
      ARRAY_INITIALIZE_COPY = Array.instance_method(:initialize_copy)
      HASH_LENGTH = Hash.instance_method(:length)
      HASH_KEYS = Hash.instance_method(:keys)
      HASH_FETCH = Hash.instance_method(:fetch)
      HASH_INITIALIZE_COPY = Hash.instance_method(:initialize_copy)
      SYMBOL_TO_S = Symbol.instance_method(:to_s)
      private_constant :MODULE_MATCH, :ARRAY_LENGTH, :ARRAY_AREF, :ARRAY_INITIALIZE_COPY,
                       :HASH_LENGTH, :HASH_KEYS, :HASH_FETCH, :HASH_INITIALIZE_COPY, :SYMBOL_TO_S

      extend Dry::Initializer

      option :scalar_snapshot
      option :byte_count

      def type(value)
        return :hash if MODULE_MATCH.bind_call(Hash, value)

        :array if MODULE_MATCH.bind_call(Array, value)
      end

      def size(source, type)
        type == :hash ? HASH_LENGTH.bind_call(source) : ARRAY_LENGTH.bind_call(source)
      end

      def snapshot(source, type)
        target = type == :hash ? Hash.allocate : Array.allocate
        initializer = type == :hash ? HASH_INITIALIZE_COPY : ARRAY_INITIALIZE_COPY
        initializer.bind_call(target, source)
        target.freeze
      end

      def target(type, size) = type == :hash ? {} : Array.new(size)

      def append_children(pending:, source:, target:, depth:, metrics:)
        if type(source) == :hash
          append_hash_children(pending, source, target, depth, metrics)
        else
          append_array_children(pending, source, target, depth, metrics)
        end
      end

      private

      def append_array_children(pending, source, target, depth, metrics)
        (ARRAY_LENGTH.bind_call(source) - 1).downto(0) do |index|
          child = ARRAY_AREF.bind_call(source, index)
          pending << [:visit, child, target, index, depth + 1, metrics]
        end
      end

      def append_hash_children(pending, source, target, depth, metrics)
        expected_size = HASH_LENGTH.bind_call(source)
        keys = HASH_KEYS.bind_call(source)
        unless ARRAY_LENGTH.bind_call(keys) == expected_size
          raise Error, "tool argument object changed while it was being captured"
        end

        capture_hash_pairs(source, keys, expected_size, metrics).reverse_each do |key, child|
          pending << [:visit, child, target, key, depth + 1, metrics]
        end
      rescue KeyError
        raise Error, "tool argument object changed while it was being captured"
      end

      def capture_hash_pairs(source, keys, expected_size, metrics)
        pairs = Array.new(expected_size)
        canonical_keys = {}
        keys.each_with_index do |source_key, index|
          copied_key = copy_hash_key(source_key, canonical_keys, metrics)
          pairs[index] = [copied_key, HASH_FETCH.bind_call(source, source_key)]
        end
        pairs
      end

      def copy_hash_key(key, canonical_keys, metrics)
        previous_bytes = byte_count.call
        copied_key = scalar_snapshot.copy_key(key)
        canonical = MODULE_MATCH.bind_call(String, copied_key) ? copied_key : SYMBOL_TO_S.bind_call(copied_key)
        raise Error, "tool arguments contain duplicate canonical Hash keys" if canonical_keys.key?(canonical)

        canonical_keys[canonical] = true
        metrics[:byte_count] += byte_count.call - previous_bytes
        copied_key
      end
    end
  end
end
