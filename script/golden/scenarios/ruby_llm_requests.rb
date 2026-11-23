# frozen_string_literal: true

# What the move to RubyLLM 2.x changes in a request without an error, where
# no scenario above shows it (the upgrade's slice 1): a request with no
# output cap, cached instructions, the automatic prompt cache, a truncation
# retry, and an OpenAI model that reasons. Where a hold is what changes, the
# step holds its requests on a host's ledger. What these and the next file's
# scenarios take from RubyLLM beyond its provider code is marked "RubyLLM
# touchpoint", for the 2.x slices.
module CoreInvisibility
  CACHE_RATES = { input_cost_per_token: 0.000003, output_cost_per_token: 0.000015,
                  cache_read_cost_per_token: 0.0000003, cache_write_cost_per_token: 0.00000375 }.freeze
  # claude-sonnet-4-5 under the dated id RubyLLM resolves it to, as well.
  PIN_PRICES = { %w[anthropic claude-sonnet-5-5] => CACHE_RATES, %w[anthropic claude-sonnet-4-5] => CACHE_RATES,
                 %w[anthropic claude-sonnet-4-5-20250929] => CACHE_RATES,
                 %w[openai gpt-5] => { input_cost_per_token: 0.00000125, output_cost_per_token: 0.00001 } }.freeze

  # A one-step workflow asking `agent`, every request of its call held on
  # the scenario's ledger (its step retries a budget refusal durably, so it
  # can pause); `seeds` builds its seed messages.
  def self.held(name, agent, seeds: -> { [{ role: :user, content: "Is the clinic open?" }] }, **step)
    D.workflow(name) do
      initial_state :idle
      state :failed
      budget_ledger { |_scope| CoreInvisibility.ledger }
      seed_messages { |_context| seeds.call }
      transition :ask, from: :idle, to: :done do
        execute agent, output_to: :answer, **step
        retry_on Smith::BudgetUnavailable, attempts: 3, backoff: 60, durable: true
        on_failure :fail
      end
    end
  end

  # The pins' prices, with cache rates, and a fresh ledger admitting the
  # reservations `admit` takes.
  def self.priced_ledger(admit: ->(_count) { true })
    Smith.config.pricing = PRICES.merge(PIN_PRICES)
    self.ledger = Hosts::Ledger.new(admit:)
  end

  # 35. A step whose agent sets no output cap, held on the host's ledger.
  D.agent("GoldenUncappedAgent", :golden_uncapped, prompt: "Answer briefly.", cap: nil)
  held("GoldenUncappedWorkflow", :golden_uncapped)
  scenario(:uncapped) do |run|
    priced_ledger
    run.reply(json: R.message("Open at 8.", id: "msg_u"))
    persisted(run, GoldenUncappedWorkflow, "run-uncapped")
  end

  # 36. Instructions cached as a host caches them on RubyLLM 1.16, and a
  # cached seed system part, held on the ledger; the reply writes and reads
  # the cache and reports its thinking.
  D.agent("GoldenCachedAgent", :golden_cached) do
    # RubyLLM touchpoint: Anthropic content with a cache marker, gone in 2.x.
    instructions { |_context| RubyLLM::Providers::Anthropic::Content.new("House style: one line.", cache: true) }
  end
  held("GoldenCachedWorkflow", :golden_cached, seeds: lambda {
    [Smith::Message.system([Smith::Content.text("Clinic facts: open 8 to 6, Monday to Friday.", cache: true)]),
     { role: :user, content: "Is the clinic open?" }]
  })
  scenario(:cached_instructions) do |run|
    priced_ledger
    run.reply(json: R.with_usage(R.message("Open 8 to 6.", id: "msg_c", tokens: [40, 9]),
                                 cache_creation_input_tokens: 1_200, cache_read_input_tokens: 300,
                                 output_tokens_details: { "thinking_tokens" => 4 }))
    persisted(run, GoldenCachedWorkflow, "run-cached")
  end

  # 37. A tool loop asking for Anthropic's automatic cache, held on the
  # ledger: each request carries it, and the second reads the first's.
  D.agent("GoldenAutoCacheAgent", :golden_auto_cache, prompt: "Find the hours.") do
    tools GoldenLookup
    prompt_cache :automatic
  end
  held("GoldenAutoCacheWorkflow", :golden_auto_cache)
  scenario(:automatic_cache) do |run|
    priced_ledger
    call = R.calling("golden_lookup", id: "toolu_1", input: { "query" => "clinic" }, msg: "msg_a")
    run.reply(json: R.with_usage(call, cache_creation_input_tokens: 900))
       .reply(json: R.with_usage(R.message("Open at 8.", id: "msg_b", tokens: [12, 5]), cache_read_input_tokens: 900))
    persisted(run, GoldenAutoCacheWorkflow, "run-auto-cache")
  end

  # 38. A reply cut off at its cap, asked again with a larger one.
  D.agent("GoldenTruncatedAgent", :golden_truncated, prompt: "Answer briefly.") do
    on_truncation retry_with: { max_tokens: 2_000 }
  end
  asking("GoldenTruncatedWorkflow", :golden_truncated)
  scenario(:truncation_retry) do |run|
    run.reply(json: R.message("Open at", id: "msg_a", stop: "max_tokens", tokens: [20, 500]))
       .reply(json: R.message("Open at 8.", id: "msg_b", tokens: [20, 6]))
    persisted(run, GoldenTruncatedWorkflow, "run-truncated")
  end

  # 39. An OpenAI model that reasons, its cap named as it takes it. RubyLLM
  # touchpoint: its list names gpt-5 a model that reasons.
  D.agent("GoldenReasoningAgent", :golden_reasoning, model_id: "gpt-5", provider: :openai, prompt: "Answer briefly.")
  asking("GoldenReasoningWorkflow", :golden_reasoning)
  scenario(:reasoning_cap) do |run|
    Smith.config.pricing = PRICES.merge(PIN_PRICES)
    run.reply(json: R.completion("Open at 8.", id: "chatcmpl_r", model: "gpt-5", tokens: [12, 9, 6]))
    persisted(run, GoldenReasoningWorkflow, "run-reasoning")
  end
end
