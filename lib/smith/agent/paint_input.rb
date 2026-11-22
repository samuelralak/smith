# frozen_string_literal: true

require "stringio"

module Smith
  class Agent
    # What an image agent's chat asks the provider to paint: its system and
    # user text joined, in order, is the prompt, and the images its content
    # parts attach are drawn from, in order. A refinement round's earlier
    # answer (an assistant turn) is not sent; the feedback after it is.
    module PaintInput
      # Bytes Faraday sends as a named file part, so the provider sees the
      # image's name and kind.
      class NamedImage < StringIO
        attr_reader :path

        def initialize(bytes, name)
          super(bytes)
          @path = name
        end
      end

      module_function

      # [prompt, images]
      def of(messages)
        texts = []
        images = []
        messages.each { |message| add(message, texts, images) unless message.role.to_s == "assistant" }
        [texts.reject { _1.strip.empty? }.join("\n\n"), images]
      end

      def add(message, texts, images)
        content = message.content
        return texts << content.to_s unless content.is_a?(::RubyLLM::Content)

        texts << content.text.to_s
        content.attachments.each { |attachment| images << NamedImage.new(attachment.content, attachment.filename) }
      end
    end
  end
end
