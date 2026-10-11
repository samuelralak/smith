# frozen_string_literal: true

module Smith
  module Streaming
    # Keeps a model's `<think>...</think>` text out of a stream. Some
    # OpenAI-compatible reasoning models write their thinking into the reply
    # between these tags, and RubyLLM moves it out of the message it
    # accumulates; this does the same to the chunks as they come, a tag split
    # across chunks included, so the stream holds the text the message will.
    # Its state starts over with each provider request (`round`), as
    # RubyLLM's accumulator does, and a partial tag left at a request's end
    # is dropped, as there.
    class ThinkTags
      OPEN = "<think>"
      CLOSE = "</think>"
      private_constant :OPEN, :CLOSE

      def initialize
        @round = nil
        start_over
      end

      # The part of `text` outside thinking (nil for anything but a String).
      def strip(text, round)
        start_over(round) unless round == @round
        return unless text.is_a?(String)

        remaining = @pending + text
        @pending = +""
        output = +""
        remaining = consume(remaining, output) until remaining.empty?
        output
      end

      private

      def start_over(round = nil)
        @round = round
        @inside = false
        @pending = +""
      end

      # Up to and past the next tag, or the rest, holding back a suffix that
      # may begin the tag.
      def consume(remaining, output)
        tag = @inside ? CLOSE : OPEN
        index = remaining.index(tag)
        return hold(remaining, tag, output) unless index

        output << remaining[0, index] unless @inside
        @inside = !@inside
        remaining[(index + tag.length)..]
      end

      def hold(remaining, tag, output)
        held = held_back(remaining, tag)
        output << remaining[0, remaining.length - held] unless @inside
        @pending = remaining[remaining.length - held, held]
        +""
      end

      def held_back(text, tag)
        [text.length, tag.length - 1].min.downto(1).find { |length| text.end_with?(tag[0, length]) } || 0
      end
    end
  end
end
