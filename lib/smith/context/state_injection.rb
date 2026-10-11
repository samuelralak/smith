# frozen_string_literal: true

module Smith
  class Context
    module StateInjection
      MARKER = "[smith:injected-state]"

      def self.inject(messages, formatter:, persisted:)
        text = formatter.call(persisted).to_s
        content = "#{MARKER}\n#{text}"

        existing_index = messages.index { |message| injected_state?(message) }

        if blank?(text)
          without_marker(messages, existing_index)
        elsif existing_index
          messages.dup.tap { |msgs| msgs[existing_index] = { role: :system, content: content } }
        else
          messages + [{ role: :system, content: content }]
        end
      end

      # Only a system message carries the marker: hosts cannot admit system
      # messages, so a user, assistant or tool message that starts with the
      # marker is content, never Smith's injected state.
      def self.injected_state?(message)
        content = message[:content] || message["content"]
        (message[:role] || message["role"]).to_s == "system" && content.is_a?(String) && content.start_with?(MARKER)
      end

      def self.blank?(text) = text.valid_encoding? && text.strip.empty?

      def self.without_marker(messages, index)
        index ? messages.dup.tap { |msgs| msgs.delete_at(index) } : messages
      end
      private_class_method :blank?, :without_marker, :injected_state?
    end
  end
end
