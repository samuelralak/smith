# frozen_string_literal: true

require "json"
require "strscan"
require_relative "../canonical_json"

module Smith
  module Evals
    # JSON values as evals keep them: parsed strictly, copied and frozen.
    # Internal.
    module JSONValue
      MAX_NESTING = CanonicalJSON::MAX_DEPTH

      # What some json gem versions let through and JSON does not allow,
      # found by reading the text itself, so every version refuses the same
      # texts: a repeated key (2.11 and 2.12 keep the last before any object
      # class sees it; another language might keep the first), a comment
      # (2.x reads one) and an unknown escape (older 2.x read "\q" as "q").
      # Keys compare as UTF-16 code units, their escapes decoded, so an
      # escaped "a" and a plain one are one key. Reads a text the parser
      # accepted; O(N).
      module Strict
        STRING = %r{"(?:[^"\\]++|\\["\\/bfnrt]|\\u\h{4})*+"}
        OTHER = %r{[^"{}\[\],:/]++}
        ESCAPES = { '"' => '"', "\\" => "\\", "/" => "/", "b" => "\b", "f" => "\f", "n" => "\n", "r" => "\r",
                    "t" => "\t" }.freeze

        module_function

        # Raises ArgumentError naming the problem.
        def check!(text)
          scanner = StringScanner.new(text)
          objects = [] # a Set of keys for each open object, nil for each open array
          key_next = false
          scanner.skip(OTHER)
          until scanner.eos?
            keys = key_next && objects.last
            key_next = scanner.check(/"/) ? string!(scanner, keys) : punctuation!(scanner.getch, objects)
            scanner.skip(OTHER)
          end
        end

        # Reads a string, adding it to keys when it is a key. nil: no key
        # follows a string.
        def string!(scanner, keys)
          token = scanner.scan(STRING)
          raise ArgumentError, "not valid JSON" unless token
          raise ArgumentError, "a key appears twice" if keys && !keys.add?(units(token))
        end

        # Whether a key comes next.
        def punctuation!(char, objects)
          case char
          when "{" then objects.push(Set.new)
          when "[" then objects.push(nil)
          when "}", "]" then objects.pop
          when "/" then raise ArgumentError, "not valid JSON"
          end
          char == "{" || (char == "," && !objects.last.nil?)
        end

        # A key's UTF-16 code units, its escapes decoded.
        def units(token)
          scanner = StringScanner.new(token[1...-1])
          out = String.new(encoding: Encoding::BINARY)
          until scanner.eos?
            plain = scanner.scan(/[^\\]++/)
            out << (plain ? plain.encode(Encoding::UTF_16BE).b : escaped(scanner))
          end
          out
        end

        def escaped(scanner)
          scanner.skip(/\\/)
          return [scanner.scan(/\h{4}/).hex].pack("n") if scanner.skip(/u/)

          ESCAPES.fetch(scanner.getch).encode(Encoding::UTF_16BE).b
        end
      end
      private_constant :Strict

      module_function

      # A JSON text as plain Hashes and Arrays with String keys; nil when it
      # is not JSON, repeats a key or nests too deep. Never echoes the text.
      def parse(text)
        parse!(text)
      rescue ArgumentError
        nil
      end

      # As parse, but raises ArgumentError naming the problem (never the
      # text), the same under every json version.
      def parse!(text)
        value = parsed(text)
        Strict.check!(text)
        frozen(value)
      end

      def parsed(text)
        JSON.parse(text, allow_duplicate_key: true, max_nesting: MAX_NESTING)
      rescue JSON::NestingError
        raise ArgumentError, "nested deeper than #{MAX_NESTING} levels"
      rescue JSON::ParserError, EncodingError
        raise ArgumentError, "not valid JSON"
      end

      # A deep copy, frozen, with String keys.
      def frozen(value) = copy(value) { |key| key.to_s.dup.freeze }

      # A deep copy, frozen, with Symbol keys, as scorers read values.
      def symbolized(value) = copy(value, &:to_sym)

      # A value in its JSON form (String keys and texts), or
      # CanonicalJSON::Error when it has none.
      def normalized(value) = frozen(JSON.parse(CanonicalJSON.generate(value)))

      def utf8?(text)
        text.is_a?(String) && ((text.encoding == Encoding::UTF_8 && text.valid_encoding?) || text.ascii_only?)
      end

      def copy(value, &key)
        case value
        when Hash then value.to_h { |name, item| [key.call(name), copy(item, &key)] }.freeze
        when Array then value.map { copy(_1, &key) }.freeze
        when String then value.dup.freeze
        else value
        end
      end
    end
    private_constant :JSONValue
  end
end
