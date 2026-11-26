# frozen_string_literal: true

require "json"
require_relative "../../canonical_json"
require_relative "../../diagnostic_text"
require_relative "../../json_value"

module Smith
  module Evals
    class Recorder
      # A step's messages as its record keeps them (slice-1a design, 5.4),
      # copied from the seam's transcript (which references the chat's own
      # strings): each text, reply and thinking cut at max_message_bytes,
      # each tool result and tool call's arguments at max_tool_bytes, cut
      # with DiagnosticText (which marks the cut) and the message marked
      # "cut": true. A reply cut, or one JSON cannot hold exactly, is kept as
      # its text, and such arguments as "arguments_text". Internal. O(B) in
      # the bytes copied.
      class Messages
        NAME_BYTES = 128
        ID_BYTES = 256

        attr_reader :cut_fields

        def initialize(bounds)
          @message_bytes = bounds.fetch(:max_message_bytes)
          @tool_bytes = bounds.fetch(:max_tool_bytes)
          @cut_fields = 0
        end

        def copy(messages) = messages.map { message(_1) }.freeze

        # The messages that fit in `room` canonical bytes, and how many were
        # elided from the middle: the first, then as many of the last as fit.
        # O(B) for their B bytes.
        def self.fitted(messages, room)
          sizes = messages.map { CanonicalJSON.generate(_1).bytesize + 1 }
          return [messages, 0] if sizes.sum <= room

          kept = kept(messages, sizes, room)
          [kept, messages.length - kept.length]
        end

        # The first, if it fits, and then the last ones that fit.
        def self.kept(messages, sizes, room)
          first = sizes.first <= room ? 1 : 0
          room -= sizes.first(first).sum
          from = sizes.length
          while from > first && sizes[from - 1] <= room
            room -= sizes[from - 1]
            from -= 1
          end
          (messages.first(first) + messages.drop(from)).freeze
        end
        private_class_method :kept

        private

        def message(entry)
          limit = entry["role"] == "tool" ? @tool_bytes : @message_bytes
          @cut = false
          kept = entry.each_with_object({}) { |(key, value), copied| field(copied, key, value, limit) }
          kept["cut"] = true if @cut
          kept.freeze
        end

        def field(kept, key, value, limit)
          case key
          when "text", "thinking" then kept[key] = text(value, limit)
          when "json" then reply(kept, value, limit)
          when "tool_calls" then kept[key] = Array(value).map { tool_call(_1) }.freeze
          else kept[key] = plain(value)
          end
        end

        def text(value, limit, counted: true)
          string = value.to_s
          kept = DiagnosticText.capture(string, max_bytes: limit)
          if counted && (kept.bytesize < string.bytesize || !string.valid_encoding?)
            @cut = true
            @cut_fields += 1
          end
          kept
        end

        def reply(kept, value, limit)
          json = CanonicalJSON.generate(value)
          return kept["json"] = JSONValue.frozen(JSON.parse(json)) if json.bytesize <= limit

          kept["text"] = text(json, limit)
        rescue CanonicalJSON::Error
          kept["text"] = unrepresentable(value, limit)
        end

        def tool_call(call)
          { "id" => text(call["id"], ID_BYTES, counted: false),
            "name" => text(call["name"], NAME_BYTES, counted: false), **arguments(call["arguments"]) }.freeze
        end

        def arguments(value)
          json = CanonicalJSON.generate(value) if value.is_a?(Hash)
          return { "arguments" => JSONValue.frozen(JSON.parse(json)) } if json && json.bytesize <= @tool_bytes

          { "arguments_text" => json ? text(json, @tool_bytes) : unrepresentable(value, @tool_bytes) }
        rescue CanonicalJSON::Error
          { "arguments_text" => unrepresentable(value, @tool_bytes) }
        end

        # Kept as its text, and counted as cut: the record does not hold it
        # as it was.
        def unrepresentable(value, limit)
          @cut = true
          @cut_fields += 1
          text(value.inspect, limit, counted: false)
        end

        def plain(value)
          JSONValue.normalized(value)
        rescue CanonicalJSON::Error
          nil
        end
      end
    end
  end
end
