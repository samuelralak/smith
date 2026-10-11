# frozen_string_literal: true

require "json"

module Smith
  module Testing
    # A tool request among a stub's outputs: the tool's name as the model
    # sees it, and its arguments.
    ToolRequest = Data.define(:name, :arguments)

    # An agent's stubbed replies, and the messages each request sent.
    class Stub
      TOKENS = %i[input_tokens output_tokens cached_tokens cache_creation_tokens thinking_tokens].freeze
      DEFAULT_USAGE = { input_tokens: 10, output_tokens: 5 }.freeze
      OUTPUTS = "a stubbed output is a String, a Hash, or a tool_call (or an Array of them)"

      # ArgumentError unless the stub can answer.
      def self.check!(outputs, usage, stop_reason, stream)
        raise ArgumentError, "stub_agent needs at least one output" if outputs.empty?
        raise ArgumentError, OUTPUTS unless outputs.all? { output?(_1) }
        raise ArgumentError, "a stub's usage is token counts by #{TOKENS.join(", ")}" unless usage?(usage)
        raise ArgumentError, "a stub's stop_reason is a String" unless stop_reason.is_a?(String)
        raise ArgumentError, "a stub's stream is a piece size" unless stream.nil? || count?(stream, positive: true)
      end

      def self.output?(output)
        [String, Hash, ToolRequest].any? { output.is_a?(_1) } || tool_requests?(output)
      end

      def self.tool_requests?(output) = output.is_a?(Array) && !output.empty? && output.all?(ToolRequest)

      def self.usage?(usage) = usage.is_a?(Hash) && (usage.keys - TOKENS).empty? && usage.values.all? { count?(_1) }

      def self.count?(value, positive: false) = value.is_a?(Integer) && (positive ? value.positive? : !value.negative?)

      def initialize(outputs:, usage:, stop_reason:, stream:)
        @outputs = outputs.map { self.class.output_entry(_1) }.freeze
        @usage = DEFAULT_USAGE.merge(usage).freeze
        @stop_reason = stop_reason
        @stream = stream
        @calls = []
        @lock = Mutex.new
      end

      # An output as the stub keeps it: a String, or the tool requests of
      # one round.
      def self.output_entry(output)
        return output if output.is_a?(String)
        return Array(output).freeze if output.is_a?(ToolRequest) || tool_requests?(output)

        JSON.generate(output)
      end

      # The messages each request sent, in request order.
      def calls = @lock.synchronize { @calls.dup }

      # The reply to the next request of `chat`; a streamed one's text is
      # yielded as chunks first.
      def reply(chat)
        output, index = take(chat.messages)
        message = output.is_a?(String) ? text(output, chat, index) : tools(output, chat, index)
        pieces(message.content).each { yield chunk(_1, message) } if block_given?
        message
      end

      private

      def take(messages)
        @lock.synchronize do
          @calls << messages.dup.freeze
          [@outputs[[@calls.length, @outputs.length].min - 1], @calls.length]
        end
      end

      def text(content, chat, index) = reply_message(chat, index, @stop_reason, content:)

      # A request for tools the chat has (RubyLLM would tell the model a
      # tool it lacks is missing, and go on).
      def tools(requests, chat, index)
        check_tools!(requests, chat.tools.keys.map(&:to_s))
        calls = requests.each_with_index.to_h do |request, position|
          id = "toolu_stub_#{index}_#{position + 1}"
          [id, RubyLLM::ToolCall.new(id:, name: request.name, arguments: request.arguments)]
        end
        reply_message(chat, index, "tool_use", content: "", tool_calls: calls)
      end

      def check_tools!(requests, known)
        unknown = requests.map(&:name).find { !known.include?(_1) }
        return unless unknown

        has = known.empty? ? "it has none" : "it has #{known.join(", ")}"
        raise ArgumentError, "a stubbed tool request names #{unknown}, a tool the agent does not have (#{has})"
      end

      def reply_message(chat, index, stop_reason, **parts)
        RubyLLM::Message.new(role: :assistant, model_id: chat.model.id, **parts, **@usage,
                             raw: Providers::ResponseFacts.kept(stop_reason:, id: "msg_stub_#{index}"))
      end

      def chunk(text, message) = RubyLLM::Chunk.new(role: :assistant, content: text, model_id: message.model_id)

      def pieces(text)
        return [] if text.to_s.empty?

        @stream ? text.each_char.each_slice(@stream).map(&:join) : [text]
      end
    end
  end
end
