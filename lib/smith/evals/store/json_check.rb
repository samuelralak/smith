# frozen_string_literal: true

require "digest"
require_relative "../../canonical_json"
require_relative "../../json_value"

module Smith
  module Evals
    module Store
      # Internal. Refuses a value JSON cannot hold exactly, so a store never
      # turns one thing into another on the way (a Symbol into a String, a
      # Time into its text, NaN into an error halfway through a write): only
      # Hashes with String keys, Arrays, UTF-8 Strings, Integers, finite
      # Floats, true, false and nil, at most MAX_DEPTH levels deep, so a value
      # that holds itself is refused too. O(N) in the value's size. Messages
      # name the problem, never a value. A record's identity is its canonical
      # JSON (RFC 8785), so two texts of one value, from two json versions or
      # with keys in two orders, are one record.
      module JSONCheck
        MAX_DEPTH = JSONValue::MAX_NESTING

        module_function

        def check!(value, what, depth = 1)
          case value
          when Hash, Array then container!(value, what, depth)
          when String, Float then scalar!(value, what)
          when Integer, true, false, nil then nil
          else raise ArgumentError, "#{what} holds a #{value.class.name || "value"}, which is not JSON"
          end
        end

        def scalar!(value, what)
          if value.is_a?(String)
            raise ArgumentError, "#{what} holds a String that is not UTF-8" unless JSONValue.utf8?(value)
          elsif !value.finite?
            raise ArgumentError, "#{what} holds NaN or Infinity, which JSON cannot"
          end
        end

        # SHA-256 of the value's canonical JSON; ArgumentError when it has
        # none (an integer past 2**53 - 1, say). O(N + sum k log k).
        def identity(value, what = "a record")
          Digest::SHA256.digest(CanonicalJSON.generate(value))
        rescue CanonicalJSON::Error => e
          raise ArgumentError, "#{what} has no canonical JSON: #{e.message.delete_prefix("canonical JSON ")}"
        end

        def container!(value, what, depth)
          raise ArgumentError, "#{what} nests deeper than #{MAX_DEPTH} levels" if depth > MAX_DEPTH
          return value.each { check!(_1, what, depth + 1) } if value.is_a?(Array)

          value.each do |key, item|
            raise ArgumentError, "#{what} has a key that is not a String of UTF-8" unless JSONValue.utf8?(key)

            check!(item, what, depth + 1)
          end
        end
      end
    end
  end
end
