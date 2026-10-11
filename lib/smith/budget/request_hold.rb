# frozen_string_literal: true

require "json"

require_relative "amount"

module Smith
  module Budget
    # The hold a provider request asks a host's budget ledger for before it
    # is sent: its output cap and an estimate of its input, priced from the
    # pricing catalog.
    #
    # The output cap is the request's own (`max_tokens`, or its provider's
    # name for it, as Providers::OutputLimit reads it), else the model's
    # maximum, else for Anthropic DEFAULT_OUTPUT_CAP (what RubyLLM asks for
    # when it knows no more), else the model's context window, else
    # DEFAULT_OUTPUT_CAP; Smith.config.budget_hold_output_tokens, when set,
    # caps it. The input estimate counts text (messages, tool definitions
    # and calls, the output schema) at one token per BYTES_PER_TOKEN bytes,
    # an image at IMAGE_TOKENS, a PDF at PAGE_TOKENS a page (its pages
    # counted in it, else one per BYTES_PER_PAGE), another attachment's
    # bytes as text, and each message's framing at MESSAGE_TOKENS, and is
    # capped at the model's context window. Images and documents are
    # recognized as RubyLLM attachments and in raw content blocks (base64
    # `data` beside its media type, or a data URL). It is an estimate, not a
    # bound: what the request spent replaces it.
    module RequestHold
      BYTES_PER_TOKEN = 3
      IMAGE_TOKENS = 1_600
      PAGE_TOKENS = 2_000
      BYTES_PER_PAGE = 50_000
      MESSAGE_TOKENS = 8
      DEFAULT_OUTPUT_CAP = 4_096
      OUTPUT_CAPS = Providers::OutputLimit::PARAM_PATHS.values.flatten(1).uniq.freeze

      module_function

      # The hold for a request RubyLLM's Provider#complete is about to make,
      # from its `messages:`, `tools:`, `schema:` and `params:`.
      def for_request(provider:, model:, mode: :sync, **request)
        context_window = model.context_window if model.respond_to?(:context_window)
        input = [input_estimate(*request.values_at(:messages, :tools, :schema)), context_window].compact.min
        output = [output_cap(provider, request[:params], model), Smith.config.budget_hold_output_tokens].compact.min
        Amount.new(input_tokens: input, output_tokens: output,
                   cost: Pricing.compute_cost(model: model.id, provider: provider.to_s, input_tokens: input,
                                              output_tokens: output, mode:))
      end

      def input_estimate(messages, tools, schema)
        counter = Counter.new
        Array(messages).each { counter.message(_1) }
        tools.to_h.each_value { counter.tool(_1) }
        counter.text(schema) if schema
        counter.tokens
      end

      PAGE = %r{/Type\s*/Page(?![a-zA-Z])}n
      PAGES = ObjectSpace::WeakMap.new
      PAGES_LOCK = Mutex.new
      private_constant :PAGE, :PAGES, :PAGES_LOCK

      # A PDF's pages (its bytes from the block), counted in it once per
      # String, else one per BYTES_PER_PAGE.
      def pages(source)
        PAGES_LOCK.synchronize do
          PAGES[source] ||= begin
            bytes = yield(source).b
            counted = bytes.scan(PAGE).length
            counted.positive? ? counted : [(bytes.bytesize + BYTES_PER_PAGE - 1) / BYTES_PER_PAGE, 1].max
          end
        end
      end

      def output_cap(provider, params, model)
        paths = Providers::OutputLimit::PARAM_PATHS.fetch(provider.to_s, OUTPUT_CAPS)
        [paths.lazy.filter_map { Providers::OutputLimit.lookup(params.to_h, _1) }.first,
         (model.max_tokens if model.respond_to?(:max_tokens)),
         (DEFAULT_OUTPUT_CAP if provider.to_s == "anthropic"),
         (model.context_window if model.respond_to?(:context_window))]
          .find { _1.is_a?(Integer) && _1.positive? } || DEFAULT_OUTPUT_CAP
      end

      # Counts what a request carries: bytes of text, images, document pages
      # and messages.
      class Counter
        IMAGE_BLOCKS = %w[image input_image image_url].freeze
        DOCUMENT_BLOCKS = %w[document file input_file].freeze
        SOURCE_KEYS = %i[source inline_data inlineData].freeze
        MEDIA_KEYS = %i[media_type mime_type mimeType].freeze
        DATA_URL = %r{\Adata:([\w.+-]+/[\w.+-]+);base64,}

        def initialize
          @bytes = 0
          @images = 0
          @pages = 0
          @messages = 0
        end

        def tokens
          ((@bytes + BYTES_PER_TOKEN - 1) / BYTES_PER_TOKEN) + (@images * IMAGE_TOKENS) + (@pages * PAGE_TOKENS) +
            (@messages * MESSAGE_TOKENS)
        end

        def message(message)
          @messages += 1
          content(message.content)
          Array(message.tool_calls&.values).each { text(_1.to_h) } if message.respond_to?(:tool_calls)
          thinking = message.thinking if message.respond_to?(:thinking)
          text(thinking.text) if thinking.respond_to?(:text)
        end

        def tool(tool)
          text(tool.name)
          text(tool.description)
          text(tool.params_schema) if tool.respond_to?(:params_schema)
        end

        def content(content)
          case content
          when RubyLLM::Content::Raw then raw(content.value)
          when RubyLLM::Content
            text(content.text)
            content.attachments.each { attachment(_1) }
          else raw(content)
          end
        end

        def attachment(attachment)
          return @images += 1 if attachment.image?
          # A URL is not fetched to count it: one page.
          return @pages += 1 if attachment.url?
          return @pages += RequestHold.pages(attachment.content.to_s) { _1 } if attachment.pdf?

          @bytes += attachment.content.to_s.bytesize
        end

        # Raw content: an image block, a block of base64 data or a data URL
        # counts as what it carries; anything else as its text.
        def raw(value)
          case value
          when Hash then block(value)
          when Array then value.each { raw(_1) }
          when String then string(value)
          else text(value)
          end
        end

        def block(hash)
          kind = fetch(hash, :type).to_s
          return @images += 1 if IMAGE_BLOCKS.include?(kind)

          data, media = base64_data(hash)
          return base64(data, media) if data
          return @pages += 1 if DOCUMENT_BLOCKS.include?(kind) && !text_source?(hash)

          hash.each do |key, value|
            text(key)
            raw(value)
          end
        end

        # Anthropic's `source` (base64), Gemini's `inline_data`, or the
        # block's own `data` beside a media type.
        def base64_data(hash)
          source = first(hash, SOURCE_KEYS) || hash
          return unless source.is_a?(Hash) && fetch(source, :type) != "text"

          data = fetch(source, :data)
          media = first(source, MEDIA_KEYS)
          [data, media] if data.is_a?(String) && media.is_a?(String)
        end

        def first(hash, keys) = keys.lazy.filter_map { fetch(hash, _1) }.first

        def text_source?(hash)
          source = fetch(hash, :source)
          source.is_a?(Hash) && %w[text content].include?(fetch(source, :type).to_s)
        end

        def string(value)
          url = DATA_URL.match(value)
          url ? base64(value, url[1], from: url[0].bytesize) : text(value)
        end

        # Base64 data (from byte `from` of `encoded`): an image, a PDF's
        # pages, or its decoded size as text. Only a PDF is decoded.
        def base64(encoded, media, from: 0)
          return @images += 1 if media.start_with?("image/")
          if media == "application/pdf"
            return @pages += RequestHold.pages(encoded) { _1.byteslice(from..).unpack1("m") }
          end

          @bytes += (encoded.bytesize - from) * 3 / 4
        end

        def fetch(hash, key) = hash.key?(key) ? hash[key] : hash[key.to_s]

        def text(value)
          case value
          when nil then nil
          when String then @bytes += value.bytesize
          when Symbol then @bytes += value.to_s.bytesize
          else @bytes += JSON.generate(value).bytesize
          end
        rescue JSON::GeneratorError, JSON::NestingError, Encoding::UndefinedConversionError
          @bytes += value.to_s.bytesize
        end
      end
    end
  end
end
