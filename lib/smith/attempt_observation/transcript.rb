# frozen_string_literal: true

require "digest"
require "ruby_llm"

require_relative "../cache_markers"

module Smith
  module AttemptObservation
    # A chat's messages as Smith's plain transcript: frozen Hashes with String
    # keys, read through RubyLLM's public Message interface only (the readers
    # ResponseMemo and Budget::Continuation already use). Each entry has
    # "role" and, when present, "text", "json", "attachments" (filename, MIME
    # type and byte count when known without reading; never the bytes),
    # "tool_calls", "tool_call_id", "thinking" (its text, never the signature)
    # and "cached" (the content carried cache markers). Experimental.
    #
    # The entries and lists are frozen; the strings, a parsed reply's Hash
    # and a tool call's arguments inside them are the chat's own objects,
    # referenced, not copied, because Smith and RubyLLM go on using them.
    #
    # O(M + A + B) for M messages, A attachment descriptors and B raw content
    # blocks; no attachment's bytes are read.
    #
    # An image's attempt (`painting`) has no chat to read: its record is its
    # request, one "user" entry with the prompt as it was sent (the
    # instructions and the input's text, Smith::PaintInput) and the request's
    # "settings" (Smith::ImageRequest: size, quality, background, output
    # format), and, when an image came back, one "assistant" entry whose
    # "image" is a reference to it: its "mime_type" (as an attachment's is
    # named), its byte size ("bytes") and its SHA-256 digest ("sha256"). Never
    # the image's bytes, which only the run's artifacts keep; the digest reads
    # them once, through RubyLLM::Image's public `data`, O(I) for I bytes.
    module Transcript
      class << self
        def messages(chat_messages)
          Array(chat_messages).map { message(_1) }.freeze
        end

        # `image`: the RubyLLM::Image the provider answered, kept or not (a
        # store that failed), nil when none came back (a failed request, a
        # moderation block); an answer with no image data is not described.
        # `mime_type`: what Smith keeps it as.
        def painting(prompt, settings, image, mime_type)
          sent = { "role" => "user", "text" => prompt,
                   "settings" => settings.to_h { |key, value| [key.to_s, value] }.freeze }.freeze
          reference = image_reference(image, mime_type)
          (reference ? [sent, { "role" => "assistant", "image" => reference }.freeze] : [sent]).freeze
        end

        private

        # Decoded as Smith decodes it to keep it (Smith::PaintedAnswer).
        def image_reference(image, mime_type)
          bytes = image&.data&.unpack1("m")
          return if bytes.nil? || bytes.empty?

          { "mime_type" => mime_type, "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes) }.freeze
        end

        def message(message)
          entry = { "role" => message.role.to_s }
          entry.merge!(content(message.content))
          calls = tool_calls(message.tool_calls)
          entry["tool_calls"] = calls if calls
          entry["tool_call_id"] = message.tool_call_id if message.tool_call_id
          thinking = message.thinking&.text
          entry["thinking"] = thinking if thinking
          entry.freeze
        end

        def content(content)
          case content
          when nil then {}
          when String then { "text" => content }
          when ::RubyLLM::Content::Raw then raw(content.value)
          when ::RubyLLM::Content then rich(content)
          # A structured reply, as RubyLLM parses one under a schema.
          when Hash, Array then { "json" => content }
          else { "text" => content.to_s }
          end
        end

        def rich(content)
          entry = {}
          entry["text"] = content.text if content.text
          attachments = content.attachments.map { attachment(_1) }
          entry["attachments"] = attachments.freeze unless attachments.empty?
          entry
        end

        # Native blocks: their text blocks joined by a blank line, and whether
        # any block asked for a cache breakpoint.
        def raw(value)
          blocks = value.is_a?(Array) ? value : [value]
          texts = blocks.filter_map { |block| block_text(block) }
          entry = {}
          entry["text"] = texts.join("\n\n") unless texts.empty?
          entry["cached"] = true if blocks.any? { |block| CacheMarkers.marked?(block) }
          entry
        end

        def block_text(block)
          return block if block.is_a?(String)
          return unless block.is_a?(Hash) && [block[:type], block["type"]].include?("text")

          text = block[:text] || block["text"]
          text if text.is_a?(String)
        end

        def attachment(attachment)
          { "filename" => attachment.filename, "mime_type" => attachment.mime_type,
            "bytes" => known_size(attachment) }.freeze
        end

        # A size read without loading the content: an in-memory IO's, or a
        # local file's. A URL or any other source is never fetched for it.
        def known_size(attachment)
          source = attachment.source
          if attachment.io_like? && source.respond_to?(:size)
            source.size
          elsif attachment.path?
            File.size?(source.to_s)
          end
        rescue StandardError
          nil
        end

        def tool_calls(calls)
          return if calls.nil? || calls.empty?

          calls.values.map do |call|
            { "id" => call.id, "name" => call.name, "arguments" => call.arguments }.freeze
          end.freeze
        end
      end
    end
  end
end
