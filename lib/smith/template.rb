# frozen_string_literal: true

require "strscan"
require_relative "canonical_json"
require_relative "errors"

module Smith
  # A fill-in field had no value (nil or absent) when its template was
  # filled in, so the step fails rather than send an empty field. The
  # message names the field, never a value.
  class TemplateValueMissing < WorkflowError; end

  # Experimental. Logic-less fill-in fields, the template language of
  # definitions as data (additions design 2.3): text with {{name}} or
  # {{ name }}, a name being a letter or "_" and up to 63 letters, digits or
  # "_". Every other "{{" is refused at its line and column (Mustache
  # sections, inverted sections, closings, partials, comments, triple
  # braces, unescaped tags, delimiter changes, and anything that is not a
  # field), so the text is valid logic-less Mustache that every export
  # target can take. Values go in as they are, in one pass and with no
  # escaping: a String or Symbol as its text in UTF-8, anything else as
  # canonical JSON, so the result is always UTF-8. Pure, and not loaded by
  # `require "smith"`.
  #
  #   template = Smith::Template.new("The posting:\n{{posting}}")
  #   template.fields                    # => ["posting"]
  #   template.render(posting: "...")    # => "The posting:\n..."
  #
  # Reading is O(L) for L bytes of text (each refused tag's position costs
  # O(L), for at most MAX_PROBLEMS of them) and O(F) space for F fields;
  # filling in is O(L + V) for V bytes of values.
  class Template
    FIELD = /( ?)([A-Za-z_][A-Za-z0-9_]{0,63})\1\}\}/
    OPEN = /\{\{/
    REFUSED = { "#" => "a Mustache section", "^" => "an inverted section", "/" => "a section's closing",
                ">" => "a partial", "!" => "a comment", "{" => "triple braces", "&" => "an unescaped tag",
                "=" => "a delimiter change" }.freeze
    RULE = "fill-in fields are {{name}} or {{ name }} only"
    MAX_PROBLEMS = 100
    private_constant :FIELD, :OPEN, :REFUSED, :RULE

    # Each refused tag of a text, as "{{# at line 1, column 5: a Mustache
    # section; ...", at most MAX_PROBLEMS; empty when it is a template.
    def self.problems(text) = Reading.new(text).problems

    # Field names in order of first appearance, each once.
    attr_reader :fields

    def initialize(text)
      reading = Reading.new(text)
      raise ArgumentError, "the template is invalid: #{reading.problems.join("; ")}" unless reading.problems.empty?

      @literals = reading.literals.freeze
      @names = reading.names.freeze
      @fields = @names.uniq.freeze
      freeze
    end

    # How many fill-in tags the text holds, repeats included.
    def field_count = @names.size

    # The text with every field filled in from `values` (String or Symbol
    # keys), in UTF-8. Raises TemplateValueMissing for a field whose value
    # is nil or absent, and CanonicalJSON::Error, naming only the field or
    # the class, for a value with no JSON form: a String not valid in its
    # encoding, or with no UTF-8 form.
    def render(values)
      raise ArgumentError, "a template's values are a Hash" unless values.is_a?(Hash)

      out = String.new(@literals.first, encoding: Encoding::UTF_8)
      @names.each_with_index do |name, index|
        out << text_of(values.key?(name) ? values[name] : values[name.to_sym], name) << @literals[index + 1]
      end
      out
    end

    private

    def text_of(value, name)
      case value
      when nil then raise TemplateValueMissing, "fill-in field {{#{name}}} has no value"
      when String then utf8(value, name)
      when Symbol then utf8(value.name, name)
      else CanonicalJSON.generate(value)
      end
    end

    # A String's text in UTF-8: converted from its own encoding, a binary
    # one read as UTF-8 bytes, which is what a binary column of text holds.
    def utf8(text, name)
      return text if text.encoding == Encoding::UTF_8 ? text.valid_encoding? : text.ascii_only?

      converted = text.encoding == Encoding::BINARY ? text.dup.force_encoding(Encoding::UTF_8) : text.encode(Encoding::UTF_8)
      converted.valid_encoding? ? converted : not_text!(name)
    rescue EncodingError
      not_text!(name)
    end

    def not_text!(name) = raise(CanonicalJSON::Error, "fill-in field {{#{name}}} holds text with no UTF-8 form")

    # One pass over a text: the literal runs, the field names between them
    # and the refused tags.
    class Reading
      attr_reader :literals, :names, :problems

      def initialize(text)
        @text = utf8(text)
        @scanner = StringScanner.new(@text)
        @literals = []
        @names = []
        @problems = []
        read
      end

      private

      def utf8(text)
        raise ArgumentError, "a template is a String, not #{text.class}" unless text.is_a?(String)
        return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?
        return text.dup.force_encoding(Encoding::UTF_8) if text.ascii_only?

        raise ArgumentError, "a template is valid UTF-8"
      end

      # A refused tag skips its run of opening braces, so "{{{{" is one
      # problem, and reading stops at MAX_PROBLEMS.
      def read
        literal = +""
        while (before = @scanner.scan_until(OPEN))
          literal << before.byteslice(0, before.bytesize - 2)
          if @scanner.scan(FIELD)
            literal = field(literal)
          elsif !refused?(@scanner.pos - 2)
            return
          end
        end
        @literals << (literal << @scanner.rest).freeze
      end

      # Keeps the literal before a field and the field's name.
      def field(literal)
        @literals << literal.freeze
        @names << @scanner[2].freeze
        +""
      end

      # Records the refused tag at `start`; false once MAX_PROBLEMS are.
      def refused?(start)
        mark = @scanner.peek(1)
        what = REFUSED[mark]
        @problems << "{{#{mark if what} at #{position(start)}: #{what || "not a fill-in field"}; #{RULE}"
        @scanner.skip(/\{+/)
        @problems.size < MAX_PROBLEMS
      end

      # Line and column (in characters) of a byte offset, each from 1.
      def position(offset)
        before = @text.byteslice(0, offset)
        newline = before.rindex("\n")
        "line #{before.count("\n") + 1}, column #{newline ? before.length - newline : before.length + 1}"
      end
    end
    private_constant :Reading
  end
end
