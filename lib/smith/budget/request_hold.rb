# frozen_string_literal: true

require "json"

require_relative "amount"

module Smith
  module Budget
    # The hold a provider request asks a host's budget ledger for before it
    # is sent: its output cap (the request's `max_tokens`, or its provider's
    # name for it, else the model's, else DEFAULT_OUTPUT_CAP, what RubyLLM
    # asks Anthropic for when it knows no more), and an estimate of its
    # input. The estimate counts text (messages, tool definitions and calls,
    # the output schema) at one token per BYTES_PER_TOKEN bytes, an image at
    # IMAGE_TOKENS, another attachment's bytes as text, and each message's
    # framing at MESSAGE_TOKENS, and is capped at the model's context window.
    # It is an estimate, not a bound: what the request spent replaces it.
    module RequestHold
      BYTES_PER_TOKEN = 3
      IMAGE_TOKENS = 1_600
      MESSAGE_TOKENS = 8
      DEFAULT_OUTPUT_CAP = 4_096
      OUTPUT_CAPS = [%i[max_tokens], %i[max_completion_tokens], %i[max_output_tokens],
                     %i[generationConfig maxOutputTokens], %i[inferenceConfig maxTokens]].freeze

      module_function

      # The hold for a request RubyLLM's Provider#complete is about to make,
      # from its `messages:`, `tools:`, `schema:` and `params:`.
      def for_request(provider:, model:, mode: :sync, **request)
        context_window = model.context_window if model.respond_to?(:context_window)
        input = [input_estimate(*request.values_at(:messages, :tools, :schema)), context_window].compact.min
        output = output_cap(request[:params], model)
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

      def output_cap(params, model)
        params = params.to_h
        cap = OUTPUT_CAPS.lazy.filter_map { |path| dig(params, path) }.first
        cap ||= model.max_tokens if model.respond_to?(:max_tokens)
        cap.is_a?(Integer) && cap.positive? ? cap : DEFAULT_OUTPUT_CAP
      end

      def dig(params, path)
        path.reduce(params) do |value, key|
          break nil unless value.is_a?(Hash)

          value.key?(key) ? value[key] : value[key.to_s]
        end
      end

      # Counts what a request carries, as bytes of text and attachments.
      class Counter
        def initialize
          @bytes = 0
          @images = 0
          @messages = 0
        end

        def tokens
          ((@bytes + BYTES_PER_TOKEN - 1) / BYTES_PER_TOKEN) + (@images * IMAGE_TOKENS) + (@messages * MESSAGE_TOKENS)
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
          when RubyLLM::Content::Raw then text(content.value)
          when RubyLLM::Content
            text(content.text)
            content.attachments.each { attachment(_1) }
          else text(content)
          end
        end

        def attachment(attachment)
          return @images += 1 if attachment.image?

          # A URL's bytes are not fetched to count them: as an image would.
          return @images += 1 if attachment.url?

          @bytes += attachment.content.to_s.bytesize
        end

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
