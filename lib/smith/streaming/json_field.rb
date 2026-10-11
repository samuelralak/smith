# frozen_string_literal: true

require_relative "json_string"

module Smith
  module Streaming
    # The growing value of one top-level string field of a JSON object
    # that arrives as text in pieces (a step with an output schema streams
    # its JSON):
    #
    #   field = Smith::Streaming::JsonField.new(:reply)
    #   def delta(text) = (piece = field.push(text)) && screen.append(piece)
    #   def reset(_reason) = field.reset || screen.clear
    #
    # `push` returns the text the piece added to the field, unescaped, or
    # nil when it added none; `value` is the field's text so far. Text before
    # the object (a code fence) is skipped. The field is read from the first
    # top-level object only (keys unescaped as JSON reads them), from the
    # first member of that name whose value is a string: a later duplicate,
    # which `JSON.parse` would take, comes after the text already streamed.
    # Work and memory are linear in the text pushed.
    class JsonField
      WHITESPACE = " \t\n\r"
      private_constant :WHITESPACE

      def initialize(name)
        unless (name.is_a?(Symbol) || name.is_a?(String)) && !name.to_s.empty?
          raise ArgumentError, "a JsonField is named by a Symbol or String"
        end

        @name = name.to_s.freeze
        reset
      end

      def push(text)
        before = @string.text.bytesize
        text.to_s.each_char { |char| step(char) }
        @string.text.byteslice(before..).freeze if @string.text.bytesize > before
      end

      def value = @string.text.dup.freeze

      # Starts over, for text that replaces what was pushed.
      def reset
        @state = :outside
        @depth = 0
        @in_string = @escape = @expect_key = @armed = false
        @key = @last_key = nil
        @string = JsonString.new
        nil
      end

      private

      def step(char)
        case @state
        when :outside then enter_object if char == "{"
        when :scan then @in_string ? scan_string(char) : scan(char)
        when :capture then capture(char)
        end
      end

      def enter_object
        @state = :scan
        @depth = 1
        @expect_key = true
      end

      def scan(char)
        return if WHITESPACE.include?(char)
        return value_start(char) if @armed

        case char
        when '"' then open_string
        when "{", "[" then @depth += 1
        when "}", "]" then close_container
        else separator(char) if @depth == 1
        end
      end

      # The first character of the value after the field's key.
      def value_start(char)
        @armed = false
        return @state = :capture if char == '"'

        scan(char)
      end

      def open_string
        @in_string = true
        @key = JsonString.new(limit: @name.length) if @expect_key
      end

      def close_container
        @depth -= 1
        @state = :done if @depth.zero?
      end

      # A member's `:` after its key, or the `,` before the next member.
      def separator(char)
        if char == ":"
          @expect_key = false
          @armed = @last_key == @name
        elsif char == ","
          @expect_key = true
        end
      end

      # Inside a string that is not the field's value: a key is read as JSON
      # reads it, up to the length of the field's name; any other string is
      # skipped to its closing quote.
      def scan_string(char)
        return key_string(char) if @key

        if @escape then @escape = false
        elsif char == "\\" then @escape = true
        elsif char == '"' then @in_string = false
        end
      end

      def key_string(char)
        @key.add(char)
        return unless @key.closed?

        @in_string = false
        @last_key = @key.overflowed? ? nil : @key.text
        @key = nil
      end

      def capture(char)
        @string.add(char)
        @state = :done if @string.closed?
      end
    end
  end
end
