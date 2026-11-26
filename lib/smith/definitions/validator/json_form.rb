# frozen_string_literal: true

require_relative "../../canonical_json"
require_relative "../../json_value"

module Smith
  module Definitions
    class Validator
      # A document in its JSON form: a JSON text read strictly (a repeated
      # key, a comment or an unknown escape refused under every json
      # version), or a Hash copied with String keys and Strings for Symbols,
      # deeply frozen, so it loads as it was written and nothing the host
      # holds can change it later; a text's value is read once, and this is
      # its only copy. Only numbers canonical JSON writes pass, so the
      # document's canonical JSON reads back as itself (no NaN or infinity,
      # nothing it writes as an integer past 2**53 - 1: CanonicalJSON's
      # rule), each with one spelling in every language: no negative zero,
      # no float whose shortest form needs an exponent. O(N + B) for N
      # values and B bytes, stopped at the bounds of Format.
      class JSONForm
        include Checks

        def initialize(problems)
          @problems = problems
          @values = 0
          @bytes = 0
        end

        # The copy, or nil with the problems recorded.
        def read(value)
          return document(value) if value.is_a?(Hash)
          return text(value) if value.is_a?(String)

          problem("", "is a JSON object, or its text, not #{value.class}")
        end

        private

        def text(text)
          return problem("", "is more than #{MAX_BYTES} bytes of JSON") if text.bytesize > MAX_BYTES

          parsed, reason = parsed(text)
          return problem("", reason) if reason

          parsed.is_a?(Hash) ? document(parsed) : problem("", "is a JSON object, or its text, not #{parsed.class}")
        end

        # JSONValue's value, or its reason in the format's words.
        def parsed(text)
          [JSONValue.read!(text), nil]
        rescue ArgumentError => e
          return [nil, "nests deeper than #{MAX_DEPTH} levels"] if e.message.start_with?("nested")

          [nil, e.message == "not valid JSON" ? "is not valid JSON" : "is not valid JSON: #{e.message}"]
        end

        def document(hash)
          copy = catch(:bounded) { value(hash, "", 1) }
          return unless @problems.empty?
          return copy unless CanonicalJSON.generate(copy).bytesize > MAX_BYTES

          problem("", "is more than #{MAX_BYTES} bytes of JSON")
        end

        def value(value, path, depth)
          bound!(@values += 1, MAX_VALUES, "holds more than #{MAX_VALUES} JSON values")
          return scalar(value, path) unless value.is_a?(Hash) || value.is_a?(Array)
          return problem(path, "nests deeper than #{MAX_DEPTH} levels") if depth > MAX_DEPTH
          return object(value, path, depth) if value.is_a?(Hash)

          value.each_with_index.map { |item, index| value(item, "#{path}/#{index}", depth + 1) }.freeze
        end

        def object(hash, path, depth)
          hash.each_with_object({}) do |(key, item), copy|
            name = key_name(key, path)
            next if name.nil?
            next problem(path, "has the key #{shown(name).inspect} twice") if copy.key?(name)

            copy[name] = value(item, pointer(path, name), depth + 1)
          end.freeze
        end

        def key_name(key, path)
          name = key.is_a?(Symbol) ? key.name : key
          return problem(path, "has a key that is not a String (#{key.class})") unless name.is_a?(String)
          return problem(path, "has a key that is not valid UTF-8") unless JSONValue.utf8?(name)

          string(name, path)
        end

        def scalar(value, path)
          case value
          when String, Symbol then string(value.is_a?(Symbol) ? value.name : value, path)
          when Integer, Float then number(value, path)
          when true, false, nil then value
          else problem(path, "is a #{value.class}, which has no JSON form")
          end
        end

        def string(text, path)
          return problem(path, "is not valid UTF-8") unless JSONValue.utf8?(text)

          bound!(@bytes += text.bytesize, MAX_BYTES, "is more than #{MAX_BYTES} bytes of JSON")
          text.frozen? && text.encoding == Encoding::UTF_8 ? text : text.dup.force_encoding(Encoding::UTF_8).freeze
        end

        def number(number, path)
          text = CanonicalJSON.generate(number)
          return problem(path, "is negative zero") if number.zero? && (1.0 / number).negative?
          return number unless text.include?("e")

          problem(path, "is a number whose shortest form needs an exponent")
        rescue CanonicalJSON::Error
          problem(path, number.finite? ? "is a number beyond 2**53 - 1" : "is not a finite number")
        end

        # Stops reading at a bound: the whole document is past it.
        def bound!(count, limit, line)
          return if count <= limit

          problem("", line)
          throw :bounded
        end
      end
    end
  end
end
