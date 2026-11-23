# frozen_string_literal: true

module Smith
  # What a paint answered, as an attempt's completion: the image kept in the
  # run's artifacts as a content part with the usage it reported, or, for a
  # moderation block, a refused response that cost nothing. An image drawn
  # and billed that cannot be kept (none in the answer, or a store that
  # failed) raises with its usage, so the usage is recorded before the
  # error goes on.
  module PaintedAnswer
    Painted = Data.define(:content)
    MODERATION_BLOCKED = "moderation_blocked"
    private_constant :Painted

    # An image drawn and billed that could not be kept: its usage, and why.
    class Unkept < StandardError
      attr_reader :usage, :reason

      def initialize(usage, reason)
        @usage = usage
        @reason = reason
        super(reason.message)
      end
    end
    private_constant :Unkept

    # Called on the module, so a workflow gains none of these names.
    class << self
      # An answer with no image is an output failure, billed and never asked
      # for again; one the store cannot keep goes on as the store's error.
      def painted_completion(agent_class, image)
        usage = Agent::ProviderUsage.from_image(image.usage)
        media_type = ImageRequest.media_type(agent_class)
        ref = kept(agent_class, image, usage, media_type)
        Agent::Completion.new(response: Painted.new(Content.image(ref, media_type:)), provider_usages: [usage].compact,
                              usage_complete: !usage.nil?)
      end

      def kept(agent_class, image, usage, media_type)
        bytes = image.data&.unpack1("m")
        if bytes.nil? || bytes.empty?
          raise Unkept.new(usage, OutputInvalid.new(agent_name: agent_class.register_as, model_used: image.model_id,
                                                    problems: ["the answer held no image"]))
        end

        Smith.artifacts.store(bytes, content_type: media_type)
      rescue Unkept
        raise
      rescue StandardError => e
        raise Unkept.new(usage, e)
      end
      private :kept

      # Nothing was drawn and nothing was billed.
      def refused_completion
        usage = Agent::ProviderUsage.new(input_tokens: 0, output_tokens: 0, stop_reason: MODERATION_BLOCKED)
        Agent::Completion.new(response: Painted.new(nil), provider_usages: [usage], usage_complete: true,
                              response_facts: { stop_reason: MODERATION_BLOCKED })
      end

      def moderation_blocked?(error)
        body = error.response.body if error.response.respond_to?(:body)
        body = JSON.parse(body) if body.is_a?(String)
        body.is_a?(Hash) && body.dig("error", "code") == MODERATION_BLOCKED
      rescue JSON::ParserError
        false
      end

      # [the usages billed, the error that goes on]: an image that could
      # not be kept gives its usage and why; any other error, none and itself.
      def unkept(error) = error.is_a?(Unkept) ? [[error.usage].compact, error.reason] : [[], error]

      # The error as the block takes it (a run's credentials scrub it), or
      # an unkept image's reason so taken, its usage kept for the record.
      def scrubbed(error)
        return yield(error) unless error.is_a?(Unkept)

        reason = yield(error.reason)
        reason.equal?(error.reason) ? error : Unkept.new(error.usage, reason)
      end
    end
  end
end
