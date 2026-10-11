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
  # the attempt's calls, and a digest of its request (model, messages,
  # tools, schema, params). A replay reaches the same key; a call whose
  # request changed since (a deployed prompt, another model, a date in the
  # prompt) misses and is sent, as a miss always may be.
  #
  # Its record, `{"version" => 1, "messages" => [...], "complete" => bool}`,
  # holds the messages the call added (Budget::Continuation, with each
  # response's usage and facts), stored after each round's tool results and
  # when the call ends; a complete one ends with the model's reply. Replayed,
  # a complete call sends nothing; an unfinished one continues from its
  # tools' results. Either way the step counts its tools as run (a retry or
  # fallback never runs them again). A call whose messages cannot be kept
  # (an attachment, or too many bytes) is not stored, and is logged. A record
  # Smith does not keep is ignored, and an error from `fetch` or `store` is
  # logged by class: a memo never fails a step. Keeping records and dropping
  # them is the host's.
  module ResponseMemo
    VERSION = 1
    PROGRESS = :smith_response_memo
    INHERITED = :smith_inherited_memo_attempts
    private_constant :PROGRESS, :INHERITED

    Recorder = Struct.new(:provider, :memo, :key, :start, :rounds, :busy)

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
               chat.tools.keys.map(&:to_s).sort, chat.schema, chat.params]
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

    # The call's kept messages and whether it ended, or nil.
    def fetch(memo, key)
      record = memo.fetch(key)
      return unless record

      record = JSON.parse(JSON.generate(record))
      raise ArgumentError, "not a response memo record" unless record?(record)

      { messages: Budget::Continuation.load(record["messages"]), complete: record["complete"] }
    rescue StandardError => e
      Smith.config.logger&.error("Smith response memo fetch error: #{e.class}")
      nil
    end

    def record?(record)
      record.is_a?(Hash) && record.keys.sort == %w[complete messages version] && record["version"] == VERSION &&
        [true, false].include?(record["complete"]) && Budget::Continuation.valid?(record["messages"]) &&
        (!record["complete"] || reply?(record["messages"].last))
    end

    def reply?(message) = message["role"] == "assistant" && message["tool_calls"].nil?

    # Stores the call's messages (`facts`: a streamed reply's, by message),
    # unless they cannot be kept.
    def store(memo, key, messages, complete:, facts: {})
      dumped = Budget::Continuation.dump(nil, messages, usage: true, facts:)
      return memo.store(key, { "version" => VERSION, "messages" => dumped, "complete" => complete }) if dumped

      Smith.config.logger&.info("Smith response memo: a call not kept (an attachment, or past its byte limit)")
      nil
    rescue StandardError => e
      Smith.config.logger&.error("Smith response memo store error: #{e.class}")
      nil
    end

    # Runs the block with the provider's call recorded: before each of its
    # later rounds, its messages from `start` (the round before's tool
    # results included) are stored as its progress.
    def recording(provider, memo, key, start)
      outer = Fiber[PROGRESS]
      Fiber[PROGRESS] = Recorder.new(provider, memo, key, start, 0, false)
      yield
    ensure
      Fiber[PROGRESS] = outer
    end

    # A request the provider is about to make, from RubyLLM's
    # `Provider#complete` (`messages`, its chat's).
    def round(provider, messages, &)
      recorder = Fiber[PROGRESS]
      return yield unless recorder&.provider.equal?(provider) && !recorder.busy

      recorder.rounds += 1
      store(recorder.memo, recorder.key, messages.drop(recorder.start), complete: false) if recorder.rounds > 1
      busy(recorder, &)
    end

    def busy(recorder)
      recorder.busy = true
      yield
    ensure
      recorder.busy = false
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
