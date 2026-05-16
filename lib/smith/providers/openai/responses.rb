# frozen_string_literal: true

# VENDORED FROM: crmne/ruby_llm PR #770
# Pinned SHA: a84517db65d3774c6b129dc88032fe32c8dbc722
# Source path: lib/ruby_llm/providers/openai/responses.rb (rev a84517d)
# License: MIT (matches RubyLLM upstream)
#
# Re-namespaced under `Smith::Providers::OpenAI::Responses`. The
# render/parse methods are vendored verbatim (only constant qualification
# changed: `Utils` → `::RubyLLM::Utils`, `Message` → `::RubyLLM::Message`,
# etc.). Smith adds:
#   - `complete(provider, messages, ...)`: Smith-authored entry point
#     that the routing prepend (Smith::Providers::OpenAI::Routing) calls
#     once the normalizer flags a request for /v1/responses routing.
#     Drives HTTP dispatch via the provider's Faraday connection.
#   - Inline `format_role` + `resolve_effort` helpers (vendored from
#     PR #770's chat.rb because Smith's Responses module is standalone,
#     not mixed into the provider class as upstream does).
#
# RETIREMENT: this file goes away when PR #770 merges into RubyLLM
# (Smith bumps the ruby_llm dep + deletes this file + its routing
# branch). The retirement path is documented in UPSTREAM_PROPOSAL.md.
#
# SYNC PROTOCOL: do NOT edit "vendored verbatim" methods directly. To
# pull upstream changes before PR #770 merges, re-pin the SHA, re-fetch
# via `gh api repos/crmne/ruby_llm/contents/lib/ruby_llm/providers/
# openai/responses.rb?ref=<SHA>`, and replace the vendored block.
# Smith-authored additions are clearly marked "SMITH-AUTHORED".

require "json"
require "ruby_llm"

module Smith
  module Providers
    module OpenAI
      # Responses API adapter consumed by Smith::Providers::OpenAI::Routing
      # when Smith::Models::Normalizer flags a request for routing via
      # OpenAI /v1/responses (typically: gpt-5 family + tools + thinking).
      module Responses
        # ---- Vendored verbatim from PR #770 responses.rb -----------------

        RESPONSE_REASONING_TEXT_TYPES = %w[summary_text output_text].freeze

        def self.responses_url
          "responses"
        end

        # SMITH-AUTHORED entry point. Routing prepend calls this with
        # the OpenAI provider instance + the same kwargs `complete`
        # would receive. Renders the /v1/responses payload using the
        # vendored helpers, POSTs via the provider's Faraday connection,
        # parses the response back into a RubyLLM::Message.
        #
        # Streaming is intentionally NOT supported in this initial vendor
        # because Smith's workflow execution path doesn't use it.
        # Block-given calls raise NotImplementedError with a clear
        # message so the host can either disable streaming or fall back
        # to `openai_api_mode = :off`.
        def self.complete(provider, messages, tools:, temperature:, model:, params: {}, headers: {},
                          schema: nil, thinking: nil, tool_prefs: nil, &block)
          if block
            raise NotImplementedError,
                  "Smith::Providers::OpenAI::Responses does not yet support streaming. " \
                  "Streaming over /v1/responses needs a separate stream_response port from PR #770. " \
                  "Workaround: pass no block (sync only), or set Smith.config.openai_api_mode = :off " \
                  "to route via chat-completions with graceful tool-dropping."
          end

          payload = render_response_payload(
            messages,
            tools: tools,
            temperature: temperature,
            model: model,
            stream: false,
            schema: schema,
            thinking: thinking,
            tool_prefs: tool_prefs
          )
          payload = ::RubyLLM::Utils.deep_merge(payload, params) unless params.empty?

          connection = provider.instance_variable_get(:@connection)
          provider_headers = provider.send(:headers)
          merged_headers = provider_headers.merge(headers)

          http_response = connection.post(responses_url, payload) do |req|
            merged_headers.each { |k, v| req.headers[k] = v }
          end

          parse_response_response(http_response, provider: provider)
        end

        # rubocop:disable Metrics/ParameterLists
        def self.render_response_payload(messages, tools:, temperature:, model:, stream: false, schema: nil,
                                         thinking: nil, tool_prefs: nil, native_tools: nil)
          tool_prefs ||= {}
          payload = {
            model: model.id,
            input: format_response_input(messages),
            stream: stream,
            store: false
          }

          payload[:temperature] = temperature unless temperature.nil?
          apply_response_tools(payload, tools, native_tools, tool_prefs)
          apply_response_schema(payload, schema) if schema
          apply_response_thinking(payload, thinking)
          payload
        end
        # rubocop:enable Metrics/ParameterLists

        def self.format_response_input(messages)
          messages.flat_map do |message|
            if message.tool_call?
              format_response_tool_calls(message.tool_calls)
            elsif message.role == :tool
              format_response_tool_result(message)
            else
              format_response_message(message)
            end
          end
        end

        # SMITH-AUTHORED kwarg addition: `provider:` is passed in so this
        # standalone module can read `@config.openai_use_system_role` for
        # `format_role`. Upstream method lives on the provider instance
        # and reads `@config` directly; Smith's standalone module needs
        # the indirection.
        def self.parse_response_response(response, provider: nil) # rubocop:disable Lint/UnusedMethodArgument
          data = response.body
          return if data.empty?

          raise ::RubyLLM::Error.new(response, data.dig("error", "message")) if data.dig("error", "message")

          outputs = data["output"] || []
          return if outputs.empty?

          usage = data["usage"] || {}

          ::RubyLLM::Message.new(
            role: :assistant,
            content: response_output_text(data),
            thinking: ::RubyLLM::Thinking.build(text: response_reasoning_text(outputs)),
            tool_calls: ToolsExtensions.parse_response_tool_calls(outputs),
            input_tokens: usage["input_tokens"],
            output_tokens: usage["output_tokens"],
            cached_tokens: usage.dig("input_tokens_details", "cached_tokens"),
            cache_creation_tokens: usage.dig("input_tokens_details", "cache_write_tokens") || 0,
            thinking_tokens: usage.dig("output_tokens_details", "reasoning_tokens"),
            model_id: data["model"],
            raw: response
          )
        end

        def self.format_response_message(message, provider: nil)
          {
            type: "message",
            role: format_role(message.role, provider: provider),
            content: format_response_content(message.content)
          }.compact
        end

        def self.format_response_tool_calls(tool_calls)
          tool_calls.map do |_, tool_call|
            {
              type: "function_call",
              call_id: tool_call.id,
              name: tool_call.name,
              arguments: JSON.generate(tool_call.arguments || {})
            }
          end
        end

        def self.format_response_tool_result(message)
          {
            type: "function_call_output",
            call_id: message.tool_call_id,
            output: response_tool_output(message.content)
          }
        end

        def self.apply_response_tools(payload, tools, native_tools, tool_prefs)
          response_tools = tools.map { |_, tool| ToolsExtensions.response_tool_for(tool) }
          response_tools.concat(::RubyLLM::Utils.to_safe_array(native_tools))
          payload[:tools] = response_tools if response_tools.any?
          unless tool_prefs[:choice].nil?
            payload[:tool_choice] = ToolsExtensions.build_response_tool_choice(tool_prefs[:choice])
          end
          payload[:parallel_tool_calls] = tool_prefs[:calls] == :many unless tool_prefs[:calls].nil?
        end

        def self.apply_response_schema(payload, schema)
          payload[:text] = {
            format: {
              type: "json_schema",
              name: schema[:name],
              schema: schema[:schema],
              strict: schema[:strict]
            }
          }
        end

        def self.apply_response_thinking(payload, thinking)
          effort = resolve_effort(thinking)
          payload[:reasoning] = { effort: effort } if effort
        end

        def self.format_response_content(content)
          return content.value if content.is_a?(::RubyLLM::Content::Raw)
          return content.to_json if content.is_a?(Hash) || content.is_a?(Array)
          return content unless content.is_a?(::RubyLLM::Content)

          parts = []
          parts << format_response_text(content.text) if content.text

          content.attachments.each do |attachment|
            parts << format_response_attachment(attachment)
          end

          parts
        end

        def self.format_response_attachment(attachment)
          case attachment.type
          when :image
            {
              type: "input_image",
              image_url: attachment.url? ? attachment.source.to_s : attachment.for_llm
            }
          when :pdf
            {
              type: "input_file",
              filename: attachment.filename,
              file_data: attachment.for_llm
            }
          when :text
            format_response_text(attachment.for_llm)
          when :audio
            raise ::RubyLLM::UnsupportedAttachmentError, "OpenAI Responses API does not support audio inputs yet"
          else
            raise ::RubyLLM::UnsupportedAttachmentError, attachment.type
          end
        end

        def self.format_response_text(text)
          {
            type: "input_text",
            text: text
          }
        end

        def self.response_tool_output(content)
          return JSON.generate(content.value) if content.is_a?(::RubyLLM::Content::Raw)
          return content.text.to_s if content.is_a?(::RubyLLM::Content) && content.text
          return JSON.generate(content.to_h) if content.is_a?(::RubyLLM::Content)
          return JSON.generate(content) if content.is_a?(Hash) || content.is_a?(Array)

          content.to_s
        end

        def self.response_output_text(data)
          output_text = data["output_text"]
          return output_text if output_text.is_a?(String) && !output_text.empty?

          text = response_output_text_parts(data["output"]).join
          text.empty? ? nil : text
        end

        def self.response_output_text_parts(outputs)
          ::RubyLLM::Utils.to_safe_array(outputs).select { |output| output["type"] == "message" }.flat_map do |output|
            ::RubyLLM::Utils.to_safe_array(output["content"]).filter_map do |content|
              content["text"] if content["type"] == "output_text" && content["text"].is_a?(String)
            end
          end
        end

        def self.response_reasoning_text(outputs)
          text = outputs.select { |output| output["type"] == "reasoning" }.flat_map do |output|
            ::RubyLLM::Utils.to_safe_array(output["summary"] || output["content"]).filter_map do |content|
              if RESPONSE_REASONING_TEXT_TYPES.include?(content["type"]) && content["text"].is_a?(String)
                content["text"]
              end
            end
          end.join

          text.empty? ? nil : text
        end

        # ---- SMITH-AUTHORED helpers (inlined from PR #770 chat.rb) -------
        #
        # Upstream PR #770 keeps these on the chat module (which is mixed
        # into the provider class so they're available as instance methods
        # with access to @config). Smith's vendored Responses module is
        # standalone (it can't read @config), so these helpers are
        # inlined as class methods with the provider passed in where
        # @config access is needed.

        def self.format_role(role, provider: nil)
          case role
          when :system
            config = provider&.instance_variable_get(:@config)
            (config && config.respond_to?(:openai_use_system_role) && config.openai_use_system_role) ? "system" : "developer"
          else
            role.to_s
          end
        end

        def self.resolve_effort(thinking)
          return nil unless thinking

          thinking.respond_to?(:effort) ? thinking.effort : thinking
        end
      end
    end
  end
end
