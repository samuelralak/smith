# frozen_string_literal: true

require "digest"
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
  # The text cannot guess the boundary. Inside a workflow step it is derived
  # from the run's namespace (a random UUID), the step's position, the
  # source and the text, so a step that prepares its input again after a
  # crash gets the same message; anywhere else it is random.
  #
  # Wrapping changes the text so it cannot close the block or pose as
  # another turn: anything shaped like an untrusted tag (spaces, invisible
  # characters or full-width forms included) becomes `untrusted-text`, and
  # a role label (`system:`, `assistant:`, `user:`, `tool:`, `developer:`,
  # `human:`, `ai:`) that opens any line gains "(quoted text)", also behind
  # spaces, invisible characters, brackets, quotes, `#`, `>`, `*`, `_` or
  # `-`. Ordinary text with such a line (`user: alice` in YAML) changes the
  # same way. Markdown headings, XML-like tags such as `<system>` and
  # look-alike letters are left as they are. Wrapping does not make text
  # safe to act on; it only marks where it starts and ends.
  module Untrusted
    GAP = "\\p{Cf}*"
    ROLE_WORDS = %w[system assistant user tool developer human ai].map { |role| role.chars.join(GAP) }.join("|")
    ROLE_LABEL = /
      (\A|[\n\r\v\f\u0085\u2028\u2029])
      ([\p{Space}\p{Cf}#>\[(*_"'`-]*)
      (#{ROLE_WORDS})
      ([\p{Space}\p{Cf}*_\])"'`]*[:\uFF1A\uFE55])
    /ix
    TAG = %r{[<\uFF1C][\p{Space}\p{Cf}\p{Cc}]*([/\uFF0F]?)[\p{Space}\p{Cf}\p{Cc}]*#{"untrusted".chars.join(GAP)}}i
    SOURCE = %r{\A[\w .:/-]{1,64}\z}

    module_function

    def wrap(text, source:)
      raise ArgumentError, "untrusted text must be a String" unless text.is_a?(String)

      label = source.to_s
      unless label.is_a?(String) && SOURCE.match?(label)
        raise ArgumentError, "untrusted source must be 1 to 64 letters, digits, spaces or . : / - _"
      end

      body = escape(text)
      boundary = boundary_for(label, body)
      %(<untrusted source="#{label}" boundary="#{boundary}">\n#{body}\n</untrusted boundary="#{boundary}">)
    end

    def escape(text)
      utf8 = text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      utf8.gsub(TAG) { "<#{"/" unless Regexp.last_match(1).empty?}untrusted-text" }
          .gsub(ROLE_LABEL) { Regexp.last_match.captures.insert(3, " (quoted text)").join }
    end

    # A position no idempotency key uses, so no key a step hands to another
    # service gives the boundary away.
    def boundary_for(label, body)
      scope = IdempotencyKey.__send__(:current_scope)
      return SecureRandom.hex(12) unless scope

      scope.within(:untrusted).key([label, Digest::SHA256.hexdigest(body)])[0, 24]
    end
    private_class_method :boundary_for
  end
end
