# frozen_string_literal: true

module Smith
  module IdempotencyKey
    MAX_SCOPE_DEPTH = 32
    MAX_SCOPE_NODES = 100_000

    module Canonical
      module_function

      # The JSON form a scope is hashed in: Symbols become Strings, Hash
      # entries are sorted by key, and a Float with a whole value becomes
      # the Integer, so equal scopes give equal keys whatever their key order
      # or numeric spelling (`12` and `12.0` from a model's JSON). Other
      # finite Floats keep their shortest exact text. NaN, Infinity and
      # other objects are refused, because they have no stable identity; so
      # are scopes past MAX_SCOPE_DEPTH levels or MAX_SCOPE_NODES values,
      # which bounds the work at O(MAX_SCOPE_NODES).
      def value(input, budget = [MAX_SCOPE_NODES], depth = 0)
        charge!(budget, depth)
        case input
        when nil, true, false, Integer then input
        when Float then float_value(input)
        when String, Symbol then string(input.to_s)
        when Array then input.map { |item| value(item, budget, depth + 1) }
        when Hash then hash_entries(input, budget, depth)
        else
          raise ArgumentError,
                "idempotency key scope must be built from Strings, Symbols, numbers, booleans, nil, Arrays " \
                "and Hashes, got #{DiagnosticText.error_class_name(input)}"
        end
      end

      def charge!(budget, depth)
        raise ArgumentError, "idempotency key scope is nested deeper than #{MAX_SCOPE_DEPTH} levels" if too_deep?(depth)
        return unless (budget[0] -= 1).negative?

        raise ArgumentError, "idempotency key scope has more than #{MAX_SCOPE_NODES} values"
      end

      def too_deep?(depth) = depth > MAX_SCOPE_DEPTH

      def float_value(value)
        raise ArgumentError, "idempotency key scope numbers must be finite" unless value.finite?

        value == value.truncate ? value.to_i : value
      end

      def hash_entries(hash, budget, depth)
        entries = hash.map { |key, item| [hash_key(key), value(item, budget, depth + 1)] }
        keys = entries.map(&:first)
        raise ArgumentError, "idempotency key scope has two keys with the same name" unless keys.uniq.size == keys.size

        entries.sort_by(&:first).to_h
      end

      def hash_key(key)
        return string(key.to_s) if key.is_a?(String) || key.is_a?(Symbol)

        raise ArgumentError, "idempotency key scope Hash keys must be Strings or Symbols"
      end

      def string(string)
        utf8 = string.encoding == Encoding::UTF_8 ? string : string.encode(Encoding::UTF_8)
        return utf8 if utf8.valid_encoding?

        raise EncodingError
      rescue EncodingError
        raise ArgumentError, "idempotency key scope Strings must be valid UTF-8 or convert to it"
      end
    end
    private_constant :Canonical
  end
end
