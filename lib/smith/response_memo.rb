# frozen_string_literal: true

require "json"

module Smith
  # A host's record of what a step's provider calls got
  # (`Smith.config.response_memo`: `fetch(key)` and `store(key, record)`),
  # so a step replayed after its process died reuses it instead of paying
  # again. A call (one agent call, its tool loop included) is kept under a
  # key of its position (IdempotencyKey: the run, the step, any branch or
  # nested position, the key generation), its attempt, its model in the
  # fallback chain and its place among the attempt's calls, which a replay
  # reaches again. Its record, `{"messages" => [...], "complete" => bool}`,
  # holds the messages the call added (Budget::Continuation, with each
  # response's usage), stored after each round's tool results and when the
  # call ends. Replayed, a complete call sends nothing; an unfinished one
  # continues from its tools' results, running none of them again. A record
  # Smith does not keep is ignored, and an error from `fetch` or `store` is
  # logged by class: a memo never fails a step. Keeping records and dropping
  # them is the host's.
  module ResponseMemo
    PROGRESS = :smith_response_memo
    private_constant :PROGRESS

    Recorder = Struct.new(:provider, :memo, :key, :start, :rounds, :busy)

    module_function

    # A step call's key, or nil outside a step.
    def key(attempt, candidate, call)
      IdempotencyKey.current(["smith.response", attempt, candidate, call])
    rescue WorkflowError
      nil
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
      record.is_a?(Hash) && record.keys.sort == %w[complete messages] && [true, false].include?(record["complete"]) &&
        Budget::Continuation.valid?(record["messages"])
    end

    # Stores the call's messages, unless they cannot be kept (an
    # attachment, or too many bytes).
    def store(memo, key, messages, complete:)
      dumped = Budget::Continuation.dump(nil, messages, usage: true)
      memo.store(key, { "messages" => dumped, "complete" => complete }) if dumped
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
  end
end
