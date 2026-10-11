# frozen_string_literal: true

require_relative "errors"

module Smith
  # Content parts of a Smith::Message: text, and documents and images held
  # as artifacts of the run (`Smith.artifacts.store` inside a step), never
  # as bytes, so a message with parts stays small and JSON-shaped wherever
  # it is stored or digested.
  #
  #   ref = Smith.artifacts.store(pdf_bytes, content_type: "application/pdf")
  #   Smith::Message.user([Smith::Content.document(ref, media_type: "application/pdf"),
  #                        Smith::Content.text("List the parties to this contract.")])
  #
  # `cache: true` marks the part as the end of a prefix Anthropic may cache;
  # other providers cache on their own and ignore it.
  module Content
    DOCUMENT_TYPES = %w[application/pdf text/plain].freeze
    IMAGE_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze
    MAX_TEXT_BYTES = 1024 * 1024
    MAX_REF_BYTES = 1024
    # The bytes one document part may hold when it is sent: as base64 it
    # still fits a 32 MiB request.
    MAX_PART_BYTES = 24 * 1024 * 1024
    # An artifact ref as Smith's stores make them: a run's namespace, then
    # colon-separated names of letters, digits, `-` and `_`. No path, dot or
    # NUL can reach a store through it.
    REF = /\A[A-Za-z0-9_-]+(?::[A-Za-z0-9_-]+)+\z/

    module_function

    def text(text, cache: false) = part({ "type" => "text", "text" => text }, cache)

    def document(ref, media_type:, cache: false)
      part({ "type" => "document", "artifact" => ref, "media_type" => media_type }, cache)
    end

    def image(ref, media_type:, cache: false)
      part({ "type" => "image", "artifact" => ref, "media_type" => media_type }, cache)
    end

    def part(fields, cache)
      raise WorkflowError, "a content part's cache: must be true or false" unless [true, false].include?(cache)

      check!(cache ? fields.merge("cache" => true) : fields)
    end

    # A part, String or Symbol keyed (and Symbol valued), checked and
    # returned frozen with String keys and UTF-8 Strings: a text part with
    # more than whitespace, or a document or image part naming an artifact
    # (REF) and a media type of its kind, each with an optional
    # `"cache" => true`.
    def check!(value)
      fields = value.is_a?(Hash) ? value.to_h { |key, field| [key.to_s, utf8(field)] } : {}
      unless valid?(fields)
        raise WorkflowError, "a content part is Smith::Content.text, .document or .image (documents " \
                             "#{DOCUMENT_TYPES.join(", ")}; images #{IMAGE_TYPES.join(", ")})"
      end

      fields.freeze
    end

    def utf8(field)
      return field.to_s.freeze if field.is_a?(Symbol)
      return field unless field.is_a?(String)

      field.dup.force_encoding(Encoding::UTF_8).freeze
    end

    def valid?(fields)
      return false unless fields.fetch("cache", true) == true

      keys = fields.keys - ["cache"]
      case fields["type"]
      when "text" then keys.sort == %w[text type] && text?(fields["text"])
      when "document" then held?(keys, fields, DOCUMENT_TYPES)
      when "image" then held?(keys, fields, IMAGE_TYPES)
      else false
      end
    end

    def text?(text) = bounded?(text, MAX_TEXT_BYTES) && text.match?(/\S/)

    def held?(keys, fields, media_types)
      keys.sort == %w[artifact media_type type] && bounded?(fields["artifact"], MAX_REF_BYTES) &&
        REF.match?(fields["artifact"]) && media_types.include?(fields["media_type"])
    end

    def bounded?(value, max_bytes)
      value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, max_bytes)
    end

    def cached?(part) = part["cache"] == true
    private_class_method :part, :utf8, :valid?, :text?, :held?, :bounded?
  end
end
