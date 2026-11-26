# frozen_string_literal: true

require "json"
require_relative "request"

module Smith
  module Testing
    # A tool request among a stub's outputs: the tool's name as the model
    # sees it, and its arguments.
    ToolRequest = Data.define(:name, :arguments)

    # A stubbed output with its own usage and stop reason (Testing.reply),
    # over the stub's: one sample's reply cut off, say.
    Reply = Data.define(:output, :usage, :stop_reason)

    # An agent's stubbed replies, and the messages each request sent. Its
    # outputs are a list taken in turn, or a callable given each request
    # (Request) and answering it; the callable is called outside the stub's
    # lock, so parallel branches are answered at once, and must be
    # thread-safe.
    class Stub
      TOKENS = %i[input_tokens output_tokens cached_tokens cache_creation_tokens thinking_tokens].freeze
      DEFAULT_USAGE = { input_tokens: 10, output_tokens: 5 }.freeze
      OUTPUTS = "a stubbed output is a String, a Hash, a tool_call (or an Array of them) or a reply"

      # An output as the stub sends it: its content (a String, or the tool
      # requests of one round) and, from a reply, its own usage and stop
      # reason.
      Entry = Data.define(:content, :usage, :stop_reason)
      private_constant :Entry

      # ArgumentError unless the stub can answer: a callable, or a list of
      # outputs.
      def self.check!(outputs, usage, stop_reason, stream)
        unless outputs.respond_to?(:call)
          raise ArgumentError, "stub_agent needs at least one output" if outputs.empty?
          raise ArgumentError, OUTPUTS unless outputs.all? { output?(_1) }
        end
        check_usage!(usage)
        raise ArgumentError, "a stub's stop_reason is a String" unless stop_reason.is_a?(String)
        raise ArgumentError, "a stub's stream is a piece size" unless stream.nil? || count?(stream, positive: true)
      end

      # ArgumentError unless `Testing.reply` can make one: its stop reason
      # nil (the stub's) or a String.
      def self.check_reply!(output, usage, stop_reason)
        raise ArgumentError, OUTPUTS unless plain_output?(output)

        check_usage!(usage)
        raise ArgumentError, "a reply's stop_reason is a String" unless stop_reason.nil? || stop_reason.is_a?(String)
      end

      def self.check_usage!(usage)
        raise ArgumentError, "a stub's usage is token counts by #{TOKENS.join(", ")}" unless usage?(usage)
      end

      def self.output?(output) = plain_output?(output) || output.is_a?(Reply)

      def self.plain_output?(output)
        [String, Hash, ToolRequest].any? { output.is_a?(_1) } || tool_requests?(output)
      end

      def self.tool_requests?(output) = output.is_a?(Array) && !output.empty? && output.all?(ToolRequest)

      def self.usage?(usage) = usage.is_a?(Hash) && (usage.keys - TOKENS).empty? && usage.values.all? { count?(_1) }

      def self.count?(value, positive: false) = value.is_a?(Integer) && (positive ? value.positive? : !value.negative?)

      # An output as the stub keeps it.
      def self.output_entry(output)
        return Entry.new(content: content(output.output), usage: output.usage, stop_reason: output.stop_reason) if
          output.is_a?(Reply)

        Entry.new(content: content(output), usage: nil, stop_reason: nil)
      end

      def self.content(output)
        return output if output.is_a?(String)
        return Array(output).freeze if output.is_a?(ToolRequest) || tool_requests?(output)

        JSON.generate(output)
      end
      private_class_method :content, :check_usage!, :plain_output?

      # `name`: the agent it answers, named in a refused answer.
      def initialize(outputs:, usage:, stop_reason:, stream:, name: nil)
        @answer = outputs if outputs.respond_to?(:call)
        @outputs = outputs.map { self.class.output_entry(_1) }.freeze unless @answer
        @usage = DEFAULT_USAGE.merge(usage).freeze
        @stop_reason = stop_reason
        @stream = stream
        @name = name
        @calls = []
        @lock = Mutex.new
      end

      # The messages each request sent, in request order.
      def calls = @lock.synchronize { @calls.dup }

      # The reply to the next request of `chat`; a streamed one's text is
      # yielded as chunks first.
      def reply(chat)
        entry, index = take(chat)
        message = entry.content.is_a?(String) ? text(entry, chat, index) : tools(entry, chat, index)
        pieces(message.content).each { yield chunk(_1, message) } if block_given?
        message
      end

      private

      def take(chat)
        index = @lock.synchronize do
          @calls << chat.messages.dup.freeze
          @calls.length
        end
        [@outputs ? @outputs[[index, @outputs.length].min - 1] : answered(chat, index), index]
      end

      def answered(chat, number)
        output = @answer.call(Request.from_chat(chat, agent: @name, number:))
        return self.class.output_entry(output) if self.class.output?(output)

        named = output.class.name.to_s
        raise ArgumentError, "the stub for #{@name} answered #{/\A[AEIOU]/.match?(named) ? "an" : "a"} #{named}: " \
                             "#{OUTPUTS}"
      end

      def text(entry, chat, index)
        reply_message(chat, index, entry, entry.stop_reason || @stop_reason,
                      content: entry.content)
      end

      # A request for tools the chat has (RubyLLM would tell the model a
      # tool it lacks is missing, and go on).
      def tools(entry, chat, index)
        requests = entry.content
        check_tools!(requests, chat.tools.keys.map(&:to_s))
        calls = requests.each_with_index.to_h do |request, position|
          id = "toolu_stub_#{index}_#{position + 1}"
          [id, RubyLLM::ToolCall.new(id:, name: request.name, arguments: request.arguments)]
        end
        reply_message(chat, index, entry, entry.stop_reason || "tool_use", content: "", tool_calls: calls)
      end

      def check_tools!(requests, known)
        unknown = requests.map(&:name).find { !known.include?(_1) }
        return unless unknown

        has = known.empty? ? "it has none" : "it has #{known.join(", ")}"
        raise ArgumentError, "a stubbed tool request names #{unknown}, a tool the agent does not have (#{has})"
      end

      def reply_message(chat, index, entry, stop_reason, **parts)
        RubyLLM::Message.new(role: :assistant, model_id: chat.model.id, **parts, **@usage, **entry.usage.to_h,
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
