# frozen_string_literal: true

# Image agents by inheritance, refused, held on a host's ledger, retried, and
# painting in a fan-out's items (slice 016, from its review's scenarios).
module CoreInvisibility
  # A subclass of an image agent, and an image agent under a host's base agent.
  Object.const_set("GoldenChildPaintAgent", Class.new(GoldenLonePaintAgent) { register_as :golden_child_paint })
  D.agent("GoldenHostBaseAgent", :golden_host_base, model_id: "gpt-image-test", provider: :openai, prompt: "Base.")
  Object.const_set("GoldenBasedPaintAgent", Class.new(GoldenHostBaseAgent) do
    register_as :golden_based_paint
    image size: "1024x1024", quality: "low", output_format: "jpeg"
  end)
  D.agent("GoldenToolPaintAgent", :golden_tool_paint, model_id: "gpt-image-test", provider: :openai,
                                                      prompt: "Draw.") do
    image size: "1024x1024", quality: "low"
    tools GoldenLookup
  end
  drawing("GoldenChildPaintWorkflow", :golden_child_paint)
  drawing("GoldenBasedPaintWorkflow", :golden_based_paint)
  drawing("GoldenToolPaintWorkflow", :golden_tool_paint)
  asking("GoldenStreamPaintWorkflow", :golden_lone_paint, into: :drawn, stream: :reply)
  asking("GoldenBatchPaintWorkflow", :golden_lone_paint, into: :drawn, mode: :batch)
  D.workflow("GoldenHeldPaintWorkflow") do
    initial_state :idle
    state :failed
    budget_ledger { |_scope| CoreInvisibility.ledger }
    budget total_cost: 5.0
    transition :draw, from: :idle, to: :done do
      execute :golden_fallback_paint, output_to: :drawn, input: ->(_context) { [Smith::Message.user("A pose.")] }
      on_failure :fail
    end
  end
  D.workflow("GoldenRetriedPaintWorkflow") do
    initial_state :idle
    state :failed
    transition :draw, from: :idle, to: :done do
      execute :golden_lone_paint, output_to: :drawn, input: ->(_context) { [Smith::Message.user("A pose.")] }
      retry_on Smith::AgentError, attempts: 2, backoff: 30, durable: true
      on_failure :fail
    end
  end
  D.workflow("GoldenPaintChild") do
    initial_state :idle
    state :failed
    transition :draw, from: :idle, to: :done do
      execute :golden_lone_paint, output_to: :drawn, input: ->(context) { [Smith::Message.user("Draw #{context[:room]}.")] }
      on_failure :fail
    end
  end
  D.workflow("GoldenPaintItemsWorkflow") do
    initial_state :idle
    state :failed
    budget total_cost: 2.0
    transition :draw, from: :idle, to: :drawn do
      workflow GoldenPaintChild, over: ->(context) { context[:rooms] }, item_to: :room, concurrency: 2,
                                 output_to: :drawn
      on_failure :fail
    end
  end

  # 28. An image agent's subclass and an image agent under a host's base
  # agent paint; one with tools, and one in a streamed step or a batch step,
  # is refused.
  scenario(:image_agents) do |run|
    paint_prices
    run.reply(json: R.painted(DRAWN)).reply(json: R.painted(DRAWN))
    persisted(run, GoldenChildPaintWorkflow, "run-child-paint")
    persisted(run, GoldenBasedPaintWorkflow, "run-based-paint")
    persisted(run, GoldenToolPaintWorkflow, "run-tools-paint")
    Smith.config.stream_sinks = { reply: Hosts::Sink.opener }
    persisted(run, GoldenStreamPaintWorkflow, "run-stream-paint")
    queue = Smith.config.batch_queue = Hosts::BatchQueue.new
    persisted(run, GoldenBatchPaintWorkflow, "run-batch-paint")
    run.note(:batch_items, queue.items.length)
  end

  # 29. A paint held on the host's ledger: painted, throttled to its
  # fallback, refused, lost, and not admitted.
  scenario(:image_held) do |run|
    paint_prices
    self.ledger = Hosts::Ledger.new
    run.reply(json: R.painted(DRAWN))
    persisted(run, GoldenHeldPaintWorkflow, "run-held")
    self.ledger = Hosts::Ledger.new
    run.reply(json: R.throttled, status: "429 Too Many Requests").reply(json: R.painted(DRAWN))
    persisted(run, GoldenHeldPaintWorkflow, "run-held-throttled")
    self.ledger = Hosts::Ledger.new
    run.reply(json: R.moderation_blocked, status: "400 Bad Request")
    persisted(run, GoldenHeldPaintWorkflow, "run-held-refused")
    self.ledger = Hosts::Ledger.new
    run.reply(drop: true)
    persisted(run, GoldenHeldPaintWorkflow, "run-held-dropped")
    self.ledger = Hosts::Ledger.new(admit: ->(_amount) { false })
    persisted(run, GoldenHeldPaintWorkflow, "run-held-unadmitted")
  end

  # 30. A throttled paint's durable retry, restored and resumed; a server's
  # error under the same retry, never retried.
  scenario(:image_retry_restored) do |run|
    paint_prices
    run.reply(json: R.throttled, status: "429 Too Many Requests")
    persisted(run, GoldenRetriedPaintWorkflow, "run-paint-retry")
    run.note(:expired, run.capture { run.expire(GoldenRetriedPaintWorkflow, "run-paint-retry") })
    run.reply(json: R.painted(DRAWN))
    resumed(run, GoldenRetriedPaintWorkflow, "run-paint-retry")
    run.reply(json: R.server_error, status: "500 Internal Server Error")
    persisted(run, GoldenRetriedPaintWorkflow, "run-paint-retry-500")
  end

  # 31. Items whose runs paint, within the run's budget.
  scenario(:items_painting) do |run|
    paint_prices
    2.times { run.reply(json: R.painted(DRAWN)) }
    persisted(run, GoldenPaintItemsWorkflow, "run-items-paint", context: { rooms: ["the kitchen", "the hall"] })
  end
end
