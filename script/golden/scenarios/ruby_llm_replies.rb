# frozen_string_literal: true

# What the move to RubyLLM 2.x changes without an error in how Smith reads a
# reply, a failure or a restored run, where no scenario above shows it (the
# upgrade's slice 1): a streamed reply cut at its cap, a paused tool loop
# that thinks, a refusal past a spending limit, a connection dropped once
# the request was sent, and a kept call whose reply read and wrote the cache.
module CoreInvisibility
  # 40. A streamed reply that ends at its cap without saying why.
  D.agent("GoldenStreamCapAgent", :golden_stream_cap, prompt: "Answer briefly.")
  asking("GoldenStreamCapWorkflow", :golden_stream_cap, stream: :reply)
  scenario(:streamed_limit_reached) do |run|
    Smith.config.stream_sinks = { reply: Hosts::Sink.opener }
    run.reply(events: R.streamed(["Open ", "at"], id: "msg_s", tokens: [30, 500], stop: nil))
    persisted(run, GoldenStreamCapWorkflow, "run-stream-cap")
  end

  # 41. A tool loop that thinks, paused for budget after its first round,
  # continued once the host tops up: the restored round goes back with its
  # thinking and the provider's tool call id. RubyLLM touchpoint: its list
  # knows claude-sonnet-4-5 and its thinking budget.
  D.agent("GoldenThinkingAgent", :golden_thinking, model_id: "claude-sonnet-4-5", listed: true, cap: 2_000,
                                                   prompt: "Find the hours.") do
    tools GoldenLookup
    thinking budget: 1_024
  end
  held("GoldenThinkingWorkflow", :golden_thinking)
  scenario(:paused_thinking) do |run|
    topped = false
    priced_ledger(admit: ->(count) { count != 2 || topped })
    call = R.calling("golden_lookup", id: "toolu_1", input: { "query" => "clinic" }, msg: "msg_a")
    thought = { "type" => "thinking", "thinking" => "Look the clinic up.", "signature" => "sig-1" }
    run.reply(json: call.merge("model" => "claude-sonnet-4-5", "content" => [thought, *call["content"]]))
       .reply(json: R.message("Open 8 to 6.", id: "msg_b", tokens: [40, 6], model: "claude-sonnet-4-5"))
    persisted(run, GoldenThinkingWorkflow, "run-thinking")
    topped = true
    run.note(:expired, run.capture { run.expire(GoldenThinkingWorkflow, "run-thinking") })
    resumed(run, GoldenThinkingWorkflow, "run-thinking")
  end

  # 42. Anthropic's monthly spend cap, which comes as a rate limit: Smith
  # fails the step on RubyLLM's payment-required error, which neither
  # RubyLLM 1.16 nor 2.2.3 raises for it on its own.
  D.agent("GoldenSpendAgent", :golden_spend, prompt: "Answer briefly.")
  asking("GoldenSpendWorkflow", :golden_spend)
  scenario(:spend_limit_refusal) do |run|
    run.reply(json: R.spend_capped, status: "429 Too Many Requests")
    persisted(run, GoldenSpendWorkflow, "run-spend")
  end

  # 43. The connection dropped once the request was sent: the fallback model
  # answers.
  D.agent("GoldenDroppedAgent", :golden_dropped, prompt: "Answer briefly.") do
    fallback_models model: "claude-haiku-5-5", provider: :anthropic
  end
  asking("GoldenDroppedWorkflow", :golden_dropped)
  scenario(:dropped_fallback) do |run|
    run.reply(drop: true).reply(json: R.message("Open at 8.", id: "msg_h", model: "claude-haiku-5-5"))
    persisted(run, GoldenDroppedWorkflow, "run-dropped")
  end

  # 44. A response memo replays a call killed after it was kept, whose reply
  # read and wrote the cache: nothing is sent again, the counts are kept.
  D.agent("GoldenMemoCacheAgent", :golden_memo_cache, prompt: "Answer briefly.")
  asking("GoldenMemoCacheWorkflow", :golden_memo_cache)
  scenario(:memo_cached_replay) do |run|
    Smith.config.pricing = PRICES.merge(PIN_PRICES)
    (Smith.config.response_memo = Hosts::Memo.new).crash_on = true
    kept = R.message("Kept answer.", tokens: [40, 9])
    run.reply(json: R.with_usage(kept, cache_read_input_tokens: 300, cache_creation_input_tokens: 1_200))
    persisted(run, GoldenMemoCacheWorkflow, "run-memo-cache")
    resumed(run, GoldenMemoCacheWorkflow, "run-memo-cache")
  end
end
