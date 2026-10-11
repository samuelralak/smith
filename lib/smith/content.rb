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
    # The bytes one document or image part may hold when it is sent.
    MAX_PART_BYTES = 32 * 1024 * 1024

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

    # A part, String or Symbol keyed, checked and returned frozen with String
    # keys: a text part, or a document or image part naming an artifact and
    # a media type of its kind, each with an optional `"cache" => true`.
    def check!(value)
      fields = value.is_a?(Hash) ? value.to_h { |key, field| [key.to_s, field] } : {}
      unless valid?(fields)
        raise WorkflowError, "a content part is Smith::Content.text, .document or .image (documents " \
                             "#{DOCUMENT_TYPES.join(", ")}; images #{IMAGE_TYPES.join(", ")})"
      end

      fields.transform_values { |field| field.is_a?(String) ? field.dup.freeze : field }.freeze
    end

    def valid?(fields)
      return false unless fields.fetch("cache", true) == true

      keys = fields.keys - ["cache"]
      case fields["type"]
      when "text" then keys.sort == %w[text type] && bounded?(fields["text"], MAX_TEXT_BYTES)
      when "document" then held?(keys, fields, DOCUMENT_TYPES)
      when "image" then held?(keys, fields, IMAGE_TYPES)
      else false
      end
    end

    def held?(keys, fields, media_types)
      keys.sort == %w[artifact media_type type] && bounded?(fields["artifact"], MAX_REF_BYTES) &&
        media_types.include?(fields["media_type"])
    end

    def bounded?(value, max_bytes)
      value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, max_bytes)
    end

    def cached?(part) = part["cache"] == true
    private_class_method :part, :valid?, :held?, :bounded?
  end
end
