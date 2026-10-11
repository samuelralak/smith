# frozen_string_literal: true

require "securerandom"

module Smith
  # Delimits text from outside the system (a fetched document, an inbound
  # message) before it goes into a prompt, so the model can tell it apart
  # from instructions:
  #
  #   Smith::Untrusted.wrap(document_text, source: "document")
  #   # => <untrusted source="document" boundary="9f2c...">
  #   #    ...text...
  #   #    </untrusted boundary="9f2c...">
  #
  # The boundary is random for each call, so the text cannot close the block
  # by guessing it. Inside, anything shaped like an untrusted tag and any
  # line that opens with a role label (`system:`, `assistant:`, `user:`,
  # `tool:`, `developer:`, also inside brackets or after `#` or `>`) is
  # marked as quoted text, so the text cannot pose as another turn.
  # Wrapping does not make text safe to act on; it only marks where it
  # starts and ends.
  module Untrusted
    ROLE_LABEL = /^(\s*[#>\[(*]*\s*)(system|assistant|user|tool|developer)(\s*[\])]*\s*:)/i
    TAG = %r{<(/?)untrusted}i
    SOURCE = %r{\A[\w .:/-]{1,64}\z}

    module_function

    def wrap(text, source:)
      raise ArgumentError, "untrusted text must be a String" unless text.is_a?(String)
      unless SOURCE.match?(source.to_s)
        raise ArgumentError, "untrusted source must be 1 to 64 letters, digits, spaces or . : / - _"
      end

      boundary = SecureRandom.hex(12)
      %(<untrusted source="#{source}" boundary="#{boundary}">\n#{escape(text)}\n</untrusted boundary="#{boundary}">)
    end

    def escape(text)
      utf8 = text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      utf8.gsub(TAG) { "<#{Regexp.last_match(1)}untrusted-text" }
          .gsub(ROLE_LABEL) { "#{Regexp.last_match(1)}#{Regexp.last_match(2)} (quoted text)#{Regexp.last_match(3)}" }
    end
  end
end
