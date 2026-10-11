# frozen_string_literal: true

require "base64"
require "stringio"

module Smith
  class Agent
    # A message with content parts (Smith::Message) as the provider takes
    # it, built for each attempt's chat: Anthropic gets native blocks
    # (`RubyLLM::Content::Raw`), a cached part with `cache_control`, and at
    # most MAX_CACHE_BREAKPOINTS of them in one request; any other provider
    # gets its text parts joined and its documents and images as
    # attachments, and `cache:` is ignored. Documents and images are read
    # from the run's artifacts when the chat is built; one that is missing,
    # is not a String, or exceeds Smith::Content::MAX_PART_BYTES fails the
    # step before the call.
    module ContentParts
      MAX_CACHE_BREAKPOINTS = 4
      EXTENSIONS = { "application/pdf" => "pdf", "text/plain" => "txt", "image/png" => "png",
                     "image/jpeg" => "jpg", "image/gif" => "gif", "image/webp" => "webp" }.freeze
      private_constant :MAX_CACHE_BREAKPOINTS, :EXTENSIONS

      private

      def check_cache_breakpoints!(messages, provider)
        return unless anthropic?(provider)

        cached = messages.sum { |message| message_parts(message).count { |part| Content.cached?(part) } }
        return if cached <= MAX_CACHE_BREAKPOINTS

        raise WorkflowError, "#{cached} content parts ask to be cached; Anthropic takes at most " \
                             "#{MAX_CACHE_BREAKPOINTS} cache breakpoints in one request"
      end

      def message_parts(message)
        return [] unless Message.parts?(message)

        message[:content] || message["content"]
      end

      # The message with its parts as `provider` takes them.
      def provider_parts_message(message, provider)
        parts = message_parts(message)
        content = anthropic?(provider) ? anthropic_content(parts) : provider_content(parts)
        { role: Workflow::MessageRoles.role(message).to_sym, content: }
      end

      def anthropic?(provider) = provider.to_s == "anthropic"

      def anthropic_content(parts)
        ::RubyLLM::Content::Raw.new(parts.map { |part| anthropic_block(part) })
      end

      def anthropic_block(part)
        block = case part["type"]
                when "text" then { type: "text", text: part["text"] }
                when "image" then { type: "image", source: base64_source(part) }
                else document_block(part)
                end
        Content.cached?(part) ? block.merge(cache_control: { type: "ephemeral" }) : block
      end

      def document_block(part)
        if part["media_type"] == "text/plain"
          return { type: "document", source: { type: "text", media_type: "text/plain", data: artifact_text(part) } }
        end

        { type: "document", source: base64_source(part) }
      end

      def base64_source(part)
        { type: "base64", media_type: part["media_type"], data: Base64.strict_encode64(artifact_bytes(part)) }
      end

      # Text parts joined; documents and images as attachments, after the
      # text (a system message has text parts only).
      def provider_content(parts)
        text = parts.filter_map { |part| part["text"] }.join("\n\n")
        held = parts.reject { |part| part["type"] == "text" }
        return text if held.empty?

        attachments = held.map.with_index(1) { |part, position| attachment(part, position) }
        ::RubyLLM::Content.new(text.empty? ? nil : text, attachments)
      end

      def attachment(part, position)
        name = "#{part["type"]}-#{position}.#{EXTENSIONS.fetch(part["media_type"])}"
        ::RubyLLM::Attachment.new(StringIO.new(artifact_bytes(part)), filename: name)
      end

      def artifact_text(part)
        text = artifact_bytes(part).dup.force_encoding(Encoding::UTF_8)
        return text if text.valid_encoding?

        raise WorkflowError, "a text/plain document part's artifact must hold UTF-8 text"
      end

      def artifact_bytes(part)
        bytes = Smith.artifacts.fetch(part["artifact"])
        unless bytes.is_a?(String) && bytes.bytesize <= Content::MAX_PART_BYTES
          raise WorkflowError, "the artifact of a #{part["type"]} part is missing, expired, not a String, or " \
                               "larger than #{Content::MAX_PART_BYTES} bytes"
        end

        bytes
      end
    end
  end
end
