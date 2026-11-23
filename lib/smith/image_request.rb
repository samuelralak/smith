# frozen_string_literal: true

module Smith
  # The output formats `image` takes, and the media type each image is kept
  # as. Here rather than on ImageRequest, which Agent extends, so a host
  # agent's `class << self` never finds it before its own.
  IMAGE_MEDIA_TYPES = { "png" => "image/png", "webp" => "image/webp", "jpeg" => "image/jpeg" }.freeze
  private_constant :IMAGE_MEDIA_TYPES

  # An agent that answers with an image rather than words:
  #
  #   image size: "1024x1024", quality: "low", background: "opaque", output_format: "png"
  #
  # Its attempt paints instead of chatting (ImageAttempt): its instructions
  # and its input's text are the prompt, its input's images (Content.image)
  # are drawn from in order, and its answer is the image, kept in the run's
  # artifacts, as `Smith::Content.image(ref, media_type:)`. The options are
  # the provider's own words for the request, passed as they are; the size
  # and quality also name what the image writes in the pricing catalog
  # (`image_output_tokens`), which its hold is priced from. An image agent
  # takes no tools, output schema or thinking, and its step is neither
  # streamed nor batched: none of them has a meaning for a picture.
  module ImageRequest
    def image(size:, quality:, background: nil, output_format: "png")
      options = { size:, quality:, background: }
      named = options.compact.all? { |_, value| value.is_a?(String) && !value.strip.empty? }
      raise ArgumentError, "image size:, quality: and background: are the provider's words, as Strings" unless
        named && size && quality
      unless IMAGE_MEDIA_TYPES.key?(output_format)
        raise ArgumentError, "image output_format: is one of #{IMAGE_MEDIA_TYPES.keys.join(", ")}"
      end

      @smith_image_request = { **options, output_format: }.compact.freeze
    end

    def image_request = ImageRequest.declared(self)

    def image_media_type = ImageRequest.media_type(self)

    # What `image` declared for `agent_class`, or nil. Smith reads its own
    # record, under its own prefix, never a method or variable an agent
    # may have named `image_request` for its own reasons.
    def self.declared(agent_class) = agent_class.instance_variable_get(:@smith_image_request)

    def self.media_type(agent_class)
      request = declared(agent_class)
      request && IMAGE_MEDIA_TYPES.fetch(request.fetch(:output_format))
    end
  end
end
