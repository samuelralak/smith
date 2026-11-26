# frozen_string_literal: true

module Smith
  module Definitions
    class Validator
      # What every check shares: each records "path: problem" lines in the
      # list it is given, paths being JSON Pointers ("" is the whole
      # document, written "/"), and answers nil for what it refused. A line
      # shows a key or value of the document whole up to SHOWN characters,
      # else its first SHOWN and its length, so its size is bounded whatever
      # the document holds.
      module Checks
        include Format

        CREDENTIALS = "credentials are never part of a definition"
        SHOWN = 64

        private

        def problem(path, line) = (@problems << "#{path.empty? ? "/" : path}: #{line}") && nil
        def need(fact, path, line) = fact || problem(path, line)
        def pointer(path, key) = "#{path}/#{shown(key.to_s).gsub("~", "~0").gsub("/", "~1")}"
        def shown(text) = text.length > SHOWN ? "#{text[0, SHOWN]}…(#{text.length} characters)" : text
        def text?(value) = value.is_a?(String) && !value.empty?
        def integer?(value, low) = value.is_a?(Integer) && value.between?(low, MAX_INTEGER)
        def boolean?(value) = [true, false].include?(value)
        def secret?(key) = key.downcase.gsub(/[^a-z0-9]/, "").match?(SECRET)
        def object!(value, path) = need(value.is_a?(Hash), path, "is an object")
        def list!(value, path) = need(value.is_a?(Array), path, "is a list")

        # Each key outside `allowed` refused, as "is not a field of an input
        # (title, ...)", or a credential-like one as such.
        def fields!(object, path, allowed, what)
          (object.keys - allowed).each do |key|
            problem(pointer(path, key), secret?(key) ? CREDENTIALS : "is not #{what} (#{allowed.join(", ")})")
          end
        end

        # Yields the value at a key, or records that it is required.
        def required(object, key, path)
          return problem(pointer(path, key), "is required") unless object.key?(key)

          yield object[key]
        end

        # Annotations are kept and never read: any object, but no key that
        # names a credential, at any depth.
        def annotations!(object, path)
          return unless object.key?("annotations")

          at = pointer(path, "annotations")
          secrets!(object["annotations"], at) if object!(object["annotations"], at)
        end

        def secrets!(value, path)
          case value
          when Hash
            value.each do |key, item|
              secret?(key) ? problem(pointer(path, key), CREDENTIALS) : secrets!(item, pointer(path, key))
            end
          when Array then value.each_with_index { |item, index| secrets!(item, "#{path}/#{index}") }
          end
        end
      end
    end
  end
end
