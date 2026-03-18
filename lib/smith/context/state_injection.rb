# frozen_string_literal: true

module Smith
  class Context
    module StateInjection
      MARKER = "[smith:injected-state]"

      def self.inject(messages, formatter:, persisted:)
        content = "#{MARKER}\n#{formatter.call(persisted)}"

        existing_index = messages.index { |m| m[:content]&.start_with?(MARKER) }

        if existing_index
          messages.dup.tap { |msgs| msgs[existing_index] = { role: :system, content: content } }
        else
          messages + [{ role: :system, content: content }]
        end
      end
    end
  end
end
