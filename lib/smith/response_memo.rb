# frozen_string_literal: true

require "digest"
require "json"

module Smith
  # A host's record of what a step's provider calls got
  # (`Smith.config.response_memo`: `fetch(key)` and `store(key, record)`),
  # so a step replayed after its process died reuses it instead of paying
  # again.
  #
  # A call (one agent call, its tool loop included) is kept under a key of
  # its position (IdempotencyKey: the run, the step, any branch or nested
  # position, the key generation), the attempts it runs under (the step's,
  # and each enclosing run's for a nested workflow), its attempt index (its
  # model in the fallback chain, or a follow-up's place), its place among
  # the attempt's calls, and a digest of its request (model, messages, tools
  # with their descriptions and parameters, schema, params). A replay
  # reaches the same key; a call whose request changed since (a deployed
  # prompt or tool, another model, a date in the prompt) misses and is
  # sent, as a miss always may be.
  #
  # Its record, `{"version" => 1 | 2, "messages" => [...], "complete" =>
  # bool}`, holds the messages the call added (Budget::Continuation, with
  # each response's usage and facts). It is stored when a reply calling the
  # tools its request offered comes (before they run; version 2, the only
  # shape a Smith before 0.12.2 cannot read), before each later request (the
  # tools' results included), and when the call ends in the model's reply (a
  # call a tool halted keeps only its progress). Replayed, a complete call
  # sends nothing; an unfinished one goes on from where it was kept: a reply
  # whose tools had not run answers the call's first request without
  # sending it, and its tools run again, under the same keys; kept tool
  # results count as tools the step ran (charged to its tool-call
  # allowances, and never run again by a retry or fallback). A call whose
  # messages cannot be kept (an attachment, or too many bytes) is not
  # stored, and is logged. A record Smith does not keep (its shape, or tool
  # results that do not answer its replies' calls) is ignored, and an error
  # from `fetch` or `store` is logged by class: a memo never fails a step.
  # Keeping records and dropping them is the host's.
  module ResponseMemo
    VERSION = 2
    PROGRESS = :smith_response_memo
    INHERITED = :smith_inherited_memo_attempts
    private_constant :PROGRESS, :INHERITED

    # A provider call being recorded (`recording`): its messages from
    # `start` are stored as its progress when a reply calling the tools its
    # request offered comes (with the facts its stream gave), and before
    # each later round (the round before's tool results included). A kept
    # reply whose tools had not run (`pending`) answers its first request,
    # and nothing is sent.
    class Recorder
      def initialize(provider, memo, key, start, pending)
        @provider = provider
        @memo = memo
        @key = key
        @start = start
        @pending = pending
        @rounds = 0
        @busy = false
        @facts = {}.compare_by_identity
      end

      # Whether a request `provider` is about to make is one of the call's
      # rounds (not one made inside another, as OpenAI's hook inside the
      # base class's).
      def records?(provider) = provider.equal?(@provider) && !@busy

      def round(messages, offered, &)
        @rounds += 1
        return @pending.tap { @pending = nil } if @pending

        progress(messages.drop(@start)) if @rounds > 1
        reply = busy(&)
        return reply unless offered && ResponseMemo.calls_tools?(reply)

        @facts[reply] = Providers::StreamFacts.last_round(@provider)
        progress([*messages.drop(@start), reply])
        reply
      end

      private

      def progress(messages) = ResponseMemo.store(@memo, @key, messages, complete: false, facts: @facts)

      def busy
        @busy = true
        yield
      ensure
        @busy = false
      end
    end

    # The shape of a record Smith keeps, as JSON.
    module Record
      READ = [1, VERSION].freeze
      private_constant :READ

      module_function

      def valid?(record)
        record.is_a?(Hash) && record.keys.sort == %w[complete messages version] && READ.include?(record["version"]) &&
          [true, false].include?(record["complete"]) && Budget::Continuation.valid?(record["messages"]) &&
          paired?(record["messages"], record["complete"])
      end

      # Each tool result answers a call of the reply before it, and a reply
      # comes only once the one before has all its results. A complete
      # record ends with a reply calling nothing; an unfinished one with all
      # of the last reply's results, or with that reply (its tools not run).
      def paired?(messages, complete)
        open = []
        messages.each do |message|
          if message["role"] == "tool"
            return false unless open.delete(message["tool_call_id"])
          else
            return false unless open.empty?

            open = Array(message["tool_calls"]).map { _1["id"] }
          end
        end
        ends?(messages.last, open, complete)
      end

      def ends?(last, open, complete)
        return reply?(last) if complete

        last["role"] == "tool" ? open.empty? : last["role"] == "assistant" && !open.empty?
      end

      def reply?(entry) = entry["role"] == "assistant" && entry["tool_calls"].nil?

      def version(entries, complete)
        last = entries.last
        !complete && last["tool_calls"] ? VERSION : 1
      end
    end

    module_function

    # A step call's key, or nil outside a step or for a request it cannot
    # digest.
    def key(attempts, candidate, call, chat)
      digest = request_digest(chat)
      IdempotencyKey.current(["smith.response", attempts, candidate, call, digest]) if digest
    rescue WorkflowError
      nil
    end

    def request_digest(chat)
      shape = [chat.model.id, chat.model.provider.to_s, chat.messages.map { message_shape(_1) },
               tools_shape(chat.tools), chat.schema, chat.params]
      Digest::SHA256.hexdigest(JSON.generate(shape))
    rescue StandardError
      nil
    end

    def message_shape(message)
      content = message.content
      body = case content
             when RubyLLM::Content::Raw then content.value
             when RubyLLM::Content
               [content.text, content.attachments.map { [_1.filename, _1.mime_type, _1.content.to_s.bytesize] }]
             else content
             end
      [message.role.to_s, body, message.tool_calls&.keys, message.tool_call_id]
    end

    def tools_shape(tools)
      tools.map { |name, tool| [name.to_s, tool.description, tool.params_schema] }.sort_by(&:first)
    end

    # The call's kept messages, whether it ended, and its reply whose tools
    # had not run (`pending`, taken off the messages), or nil.
    def fetch(memo, key)
      record = memo.fetch(key)
      return unless record

      record = JSON.parse(JSON.generate(record))
      raise ArgumentError, "not a response memo record" unless Record.valid?(record)

      kept(Budget::Continuation.load(record["messages"]), record["complete"])
    rescue StandardError => e
      Smith.config.logger&.error("Smith response memo fetch error: #{e.class}")
      nil
    end

    def kept(messages, complete)
      pending = messages.pop if !complete && calls_tools?(messages.last)
      { messages:, complete:, pending: }
    end

    def calls_tools?(message) = message.is_a?(RubyLLM::Message) && message.role == :assistant && message.tool_call?

    # Whether the message is the model's reply calling nothing, as a call
    # ends.
    def answer?(message) = message.is_a?(RubyLLM::Message) && message.role == :assistant && !message.tool_call?

    # Stores the call's messages (`facts`: a streamed reply's, by message),
    # unless they cannot be kept.
    def store(memo, key, messages, complete:, facts: {})
      dumped = Budget::Continuation.dump(nil, messages, usage: true, facts:)
      if dumped
        return memo.store(key, { "version" => Record.version(dumped, complete), "messages" => dumped,
                                 "complete" => complete })
      end

      Smith.config.logger&.info("Smith response memo: a call not kept (an attachment, or past its byte limit)")
      nil
    rescue StandardError => e
      Smith.config.logger&.error("Smith response memo store error: #{e.class}")
      nil
    end

    # Runs the block with the provider's call recorded (Recorder) from
    # `start`, its first request answered by `pending` if given.
    def recording(provider, memo, key, start, pending = nil)
      outer = Fiber[PROGRESS]
      Fiber[PROGRESS] = Recorder.new(provider, memo, key, start, pending)
      yield
    ensure
      Fiber[PROGRESS] = outer
    end

    # A request the provider is about to make, from RubyLLM's
    # `Provider#complete` (`messages`, its chat's, and the request's
    # `options`), and its reply.
    def round(provider, messages, options = {}, &)
      recorder = Fiber[PROGRESS]
      recorder&.records?(provider) ? recorder.round(messages, tools_offered?(options), &) : yield
    end

    # Whether the request offered the model tools (a finalization that took
    # them away did not, and its reply's calls never run).
    def tools_offered?(options)
      tools = options[:tools]
      tools.respond_to?(:empty?) && !tools.empty?
    end

    # A nested workflow built in the block runs its calls under `attempts`
    # too (the enclosing runs' attempts), so a retry of its parent's step is
    # never answered from the attempt before.
    def inheriting(attempts)
      outer = Thread.current[INHERITED]
      Thread.current[INHERITED] = attempts
      yield
    ensure
      Thread.current[INHERITED] = outer
    end

    def take_inherited
      attempts = Thread.current[INHERITED]
      Thread.current[INHERITED] = nil
      attempts || []
    end
  end
end
