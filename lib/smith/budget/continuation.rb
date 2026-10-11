# frozen_string_literal: true

require "json"

module Smith
  module Budget
    # The rest of a tool loop that paused for budget: the messages a step's
    # call added before a host's budget ledger refused a later round (the
    # model's tool calls, their results, its thinking and its signatures),
    # kept with the step's retry so that the retry continues the loop from
    # them instead of running its tools again. JSON-shaped and at most
    # MAX_BYTES; a loop whose messages cannot be kept so (an attachment in
    # them, or too many bytes) does not pause. A response memo
    # (Smith::ResponseMemo) keeps a call's messages the same way, with each
    # response's `usage`: its token counts, stop reason and message id.
    module Continuation
      MAX_BYTES = 1024 * 1024
      ROLES = %w[assistant tool user].freeze
      TOKENS = %w[input_tokens output_tokens cached_tokens cache_creation_tokens thinking_tokens].freeze
      MEMO_BODY = "smith.response_memo"
      # What Providers::ResponseFacts reads a kept response's facts from.
      Raw = Struct.new(:body)

      module_function

      # `kept` (an earlier pause's) followed by `messages`, or nil; with
      # `usage`, each response's usage too.
      def dump(kept, messages, usage: false)
        dumped = messages.map { message(_1, usage:) || (return nil) }
        list = JSON.parse(JSON.generate([*kept, *dumped]))
        list if JSON.generate(list).bytesize <= MAX_BYTES
      rescue JSON::GeneratorError, JSON::NestingError, Encoding::UndefinedConversionError
        nil
      end

      def message(message, usage: false)
        content = content_of(message.content)
        return if content == :unkept

        { "role" => message.role.to_s, "content" => content, "tool_call_id" => message.tool_call_id,
          "model_id" => message.model_id, "tool_calls" => message.tool_calls&.values&.map { tool_call(_1) },
          "thinking" => thinking_of(message.thinking), "usage" => (usage_of(message) if usage) }.compact
      end

      def usage_of(message)
        tokens = message.respond_to?(:tokens) ? message.tokens&.to_h : nil
        facts = Providers::ResponseFacts.from_message(message)
        usage = { "tokens" => tokens&.transform_keys(&:to_s), "stop_reason" => facts[:stop_reason],
                  "id" => facts[:provider_message_id] }.compact
        usage unless usage.empty?
      end

      def thinking_of(thinking)
        { "text" => thinking.text, "signature" => thinking.signature }.compact if thinking
      end

      def content_of(content)
        case content
        when nil, String then content
        when RubyLLM::Content::Raw then { "raw" => content.value }
        else :unkept
        end
      end

      def tool_call(call)
        { "id" => call.id, "name" => call.name, "arguments" => call.arguments,
          "thought_signature" => call.thought_signature }.compact
      end

      # The messages a kept continuation holds, for a chat; ArgumentError if
      # it is not one `dump` makes.
      def load(list)
        raise ArgumentError, "a budget continuation must be a list of messages" unless valid?(list)

        list.map do |entry|
          RubyLLM::Message.new(
            role: entry["role"].to_sym, content: content(entry["content"]), tool_call_id: entry["tool_call_id"],
            model_id: entry["model_id"], tool_calls: tool_calls(entry["tool_calls"]),
            thinking: thinking(entry["thinking"]), **kept_usage(entry["usage"])
          )
        end
      end

      # A kept response's token counts, and its facts as a raw body
      # Providers::ResponseFacts reads.
      def kept_usage(usage)
        return {} unless usage

        { **usage.fetch("tokens", {}).transform_keys(&:to_sym),
          raw: Raw.new({ "object" => MEMO_BODY, "stop_reason" => usage["stop_reason"], "id" => usage["id"] }) }
      end

      def valid?(list)
        list.is_a?(Array) && !list.empty? && JSON.generate(list).bytesize <= MAX_BYTES && list.all? { entry?(_1) }
      rescue JSON::GeneratorError, JSON::NestingError
        false
      end

      def entry?(entry)
        entry.is_a?(Hash) && ROLES.include?(entry["role"]) && content?(entry["content"]) &&
          entry.values_at("tool_call_id", "model_id").all? { optional_string?(_1) } &&
          calls?(entry["tool_calls"]) && thinking?(entry["thinking"]) && usage?(entry["usage"])
      end

      def usage?(usage)
        return true if usage.nil?
        return false unless usage.is_a?(Hash) && (usage.keys - %w[tokens stop_reason id]).empty?

        tokens?(usage.fetch("tokens", {})) && optional_string?(usage["stop_reason"]) && optional_string?(usage["id"])
      end

      def tokens?(tokens)
        tokens.is_a?(Hash) && (tokens.keys - TOKENS).empty? && tokens.values.all? { _1.is_a?(Integer) && !_1.negative? }
      end

      def calls?(calls) = calls.nil? || (calls.is_a?(Array) && calls.all? { call?(_1) })

      def thinking?(thinking) = thinking.nil? || (thinking.is_a?(Hash) && thinking.values.all?(String))

      def content?(content) = content.nil? || content.is_a?(String) || (content.is_a?(Hash) && content.keys == ["raw"])

      def call?(call)
        call.is_a?(Hash) && call["id"].is_a?(String) && call["name"].is_a?(String) && call["arguments"].is_a?(Hash) &&
          optional_string?(call["thought_signature"])
      end

      def optional_string?(value) = value.nil? || value.is_a?(String)

      def content(value) = value.is_a?(Hash) ? RubyLLM::Content::Raw.new(value.fetch("raw")) : value

      def tool_calls(calls)
        calls&.to_h do |call|
          [call["id"], RubyLLM::ToolCall.new(id: call["id"], name: call["name"], arguments: call["arguments"],
                                             thought_signature: call["thought_signature"])]
        end
      end

      def thinking(value) = value && RubyLLM::Thinking.new(text: value["text"], signature: value["signature"])
    end
  end
end
