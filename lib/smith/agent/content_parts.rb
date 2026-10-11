# frozen_string_literal: true

require "base64"
require "stringio"

module Smith
  class Agent
    # A message with content parts (Smith::Message) as the provider takes
    # it, built for each attempt's chat. Anthropic gets native blocks
    # (`RubyLLM::Content::Raw`), a cached part with `cache_control`, at most
    # MAX_CACHE_BREAKPOINTS cached blocks in the request (Smith's and the
    # chat's own). Any other provider gets the parts as one text, in order,
    # with a `text/plain` document inline and each PDF or image as an
    # attachment named where it stands in the text; `cache:` is ignored.
    #
    # The documents and images of one invocation are read from the run's
    # artifacts once, before the first attempt (ContentBytes), so a store
    # failure is never taken for a provider failure.
    module ContentParts
      MAX_CACHE_BREAKPOINTS = 4
      EXTENSIONS = { "application/pdf" => "pdf", "text/plain" => "txt", "image/png" => "png",
                     "image/jpeg" => "jpg", "image/gif" => "gif", "image/webp" => "webp" }.freeze
      private_constant :MAX_CACHE_BREAKPOINTS, :EXTENSIONS

      private

      # Counts the cached blocks already in the chat (its instructions) and
      # those the prepared input adds, before any is added.
      def check_cache_breakpoints!(chat, messages, provider)
        return unless anthropic?(provider)

        cached = chat_cache_controls(chat) +
                 messages.sum { |message| message_parts(message).count { |part| Content.cached?(part) } }
        return if cached <= MAX_CACHE_BREAKPOINTS

        raise ContentUnavailable, "#{cached} blocks ask to be cached; Anthropic takes at most " \
                                  "#{MAX_CACHE_BREAKPOINTS} cache breakpoints in one request"
      end

      def check_chain_cache_breakpoints!(chain, prepared_input)
        return unless chain.any? { |reference| anthropic?(reference.provider) }

        check_cache_breakpoints!(nil, Array(prepared_input), :anthropic)
      end

      # A model the chain reaches whose provider takes no such content.
      def unsupported_content?(error) = error.is_a?(::RubyLLM::UnsupportedAttachmentError)

      def chat_cache_controls(chat)
        return 0 unless chat.respond_to?(:messages)

        chat.messages.sum do |message|
          content = message.respond_to?(:content) ? message.content : nil
          content.is_a?(::RubyLLM::Content::Raw) ? Array(content.value).count { |block| cached_block?(block) } : 0
        end
      end

      def cached_block?(block) = block.is_a?(Hash) && !(block[:cache_control] || block["cache_control"]).nil?

      # A parts message's parts: checked where they came in (input:, seeds,
      # restore) and again before the first attempt (ContentBytes).
      def message_parts(message)
        return [] unless Message.parts?(message)

        message[:content] || message["content"]
      end

      BUILT = :smith_built_contents
      private_constant :BUILT

      # The contents Smith builds while it adds one prepared input to a
      # chat, held per thread for that call.
      def with_built_contents
        outer = Thread.current[BUILT]
        Thread.current[BUILT] = {}.compare_by_identity
        yield
      ensure
        Thread.current[BUILT] = outer
      end

      # The message with its parts as `provider` takes them; the content is
      # recorded as Smith's own, so it passes to the chat unencoded.
      def provider_parts_message(message, provider)
        parts = message_parts(message)
        content = anthropic?(provider) ? anthropic_content(parts) : provider_content(parts)
        Thread.current[BUILT]&.store(content, true)
        { role: Workflow::MessageRoles.role(message).to_sym, content: }
      end

      def built_content?(content) = Thread.current[BUILT]&.key?(content) || false

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

      # The parts in order as one text: text parts as they are, a
      # `text/plain` document inline, and a marker where each PDF or image
      # stands, attached under the marker's name.
      def provider_content(parts)
        texts = []
        attachments = []
        parts.each.with_index(1) { |part, position| add_provider_part(part, position, texts, attachments) }
        text = texts.join("\n\n")
        return text if attachments.empty?

        ::RubyLLM::Content.new(text.empty? ? nil : text, attachments)
      end

      def add_provider_part(part, position, texts, attachments)
        return texts << part["text"] if part["type"] == "text"

        name = "#{part["type"]}-#{position}.#{EXTENSIONS.fetch(part["media_type"])}"
        if part["media_type"] == "text/plain"
          texts << "<file name='#{name}' mime_type='text/plain'>#{artifact_text(part)}</file>"
        else
          texts << "[attached: #{name}]"
          attachments << ::RubyLLM::Attachment.new(StringIO.new(artifact_bytes(part)), filename: name)
        end
      end

      def artifact_text(part) = artifact_bytes(part).dup.force_encoding(Encoding::UTF_8)

      def artifact_bytes(part) = ContentBytes.fetch(part)
    end
  end
end
