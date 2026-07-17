# frozen_string_literal: true

require "dry-initializer"

require_relative "../errors"
require_relative "string_snapshot"

module Smith
  class Workflow
    class MessageValueNormalizer
      MAX_DEPTH = 64
      MAX_NODES = 100_000
      MAX_BYTES = 1 * 1024 * 1024
      INTEGER_RANGE = (-(2**63)..((2**63) - 1))
      ARRAY_EACH = Array.instance_method(:each)
      HASH_EACH_PAIR = Hash.instance_method(:each_pair)
      private_constant :ARRAY_EACH, :HASH_EACH_PAIR

      extend Dry::Initializer

      param :value

      def call
        @active = {}.compare_by_identity
        @nodes = 0
        @bytes = 0
        copy_value(value, depth: 0)
      end

      private

      def copy_value(item, depth:)
        visit!(depth)
        return copy_container_value(item, depth:) if item.is_a?(Hash) || item.is_a?(Array)

        copy_scalar(item)
      end

      def copy_container_value(item, depth:)
        copy_container(item) do
          item.is_a?(Hash) ? copy_hash(item, depth:) : copy_array(item, depth:)
        end
      end

      def copy_scalar(item)
        case item
        when String then copy_string(item)
        when Symbol then copy_string(item.to_s)
        when Integer then copy_integer(item)
        when Float then copy_float(item)
        when true, false, nil then item
        else
          reject!("session message contains unsupported value #{item.class}")
        end
      end

      def copy_container(source)
        reject!("session message contains a cyclic value") if @active.key?(source)

        @active[source] = true
        yield
      ensure
        @active.delete(source)
      end

      def copy_hash(source, depth:)
        pairs = canonical_pairs(source)
        pairs.sort_by!(&:first)
        validate_unique_keys!(pairs)

        pairs.each_with_object({}) do |(key, nested), copy|
          copy[key] = copy_value(nested, depth: depth + 1)
        end.freeze
      end

      def canonical_pairs(source)
        pairs = []
        remaining_nodes = MAX_NODES - @nodes
        HASH_EACH_PAIR.bind_call(source) do |key, nested|
          reject!("session message batch exceeds maximum size #{MAX_NODES}") if pairs.length == remaining_nodes
          reject!("session message Hash keys must be strings or symbols") unless key.is_a?(String) || key.is_a?(Symbol)

          pairs << [copy_string(key.to_s), nested]
        end
        pairs
      end

      def validate_unique_keys!(pairs)
        return unless pairs.each_cons(2).any? { |left, right| left.first == right.first }

        reject!("session message contains duplicate canonical Hash keys")
      end

      def copy_array(source, depth:)
        copy = []
        ARRAY_EACH.bind_call(source) { |nested| copy << copy_value(nested, depth: depth + 1) }
        copy.freeze
      end

      def copy_string(string)
        @bytes += StringSnapshot.bytesize(string)
        reject!("session message batch exceeds maximum bytes #{MAX_BYTES}") if @bytes > MAX_BYTES

        StringSnapshot.copy(string, freeze: true)
      end

      def copy_integer(integer)
        return integer if INTEGER_RANGE.cover?(integer)

        reject!("session message integers must fit a signed 64-bit value")
      end

      def copy_float(float)
        return float if float.finite?

        reject!("session message contains a non-finite Float")
      end

      def visit!(depth)
        reject!("session message batch exceeds maximum depth #{MAX_DEPTH}") if depth > MAX_DEPTH

        @nodes += 1
        return if @nodes <= MAX_NODES

        reject!("session message batch exceeds maximum size #{MAX_NODES}")
      end

      def reject!(message)
        raise WorkflowError, message
      end
    end
  end
end
