# frozen_string_literal: true

module Smith
  class Context
    module StateInjection
      MARKER = "[smith:injected-state]"

      def self.inject(messages, formatter:, persisted:)
        text = formatter.call(persisted).to_s
        content = "#{MARKER}\n#{text}"

        existing_index = messages.index do |message|
          message_content = message[:content] || message["content"]
          message_content.is_a?(String) && message_content.start_with?(MARKER)
        end

        if blank?(text)
          without_marker(messages, existing_index)
        elsif existing_index
          messages.dup.tap { |msgs| msgs[existing_index] = { role: :system, content: content } }
        else
          messages + [{ role: :system, content: content }]
        end
      end

      def self.blank?(text) = text.valid_encoding? && text.strip.empty?

      def self.without_marker(messages, index)
        index ? messages.dup.tap { |msgs| msgs.delete_at(index) } : messages
      end
      private_class_method :blank?, :without_marker
    end
  end
end
