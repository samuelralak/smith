# frozen_string_literal: true

# Fan-outs over items that the items scenario above does not reach (slice
# 016, from its review's scenarios): refused, failing, none, within a budget,
# retried, and after a wait.
module CoreInvisibility
  D.agent("GoldenItemAgent", :golden_item, prompt: "Describe it.")
  D.workflow("GoldenItemChild") do
    initial_state :idle
    state :failed
    seed_messages { |context| [{ role: :user, content: "Describe #{context[:room]}." }] }
    transition :describe, from: :idle, to: :done do
      execute :golden_item
      on_failure :fail
    end
  end
  D.workflow("GoldenItemRaisingChild") do
    initial_state :idle
    seed_messages { |context| [{ role: :user, content: "Describe #{context[:room]}." }] }
    transition(:describe, from: :idle, to: :done) { execute :golden_item }
  end
  def self.items(name, child, budget: nil, retried: false, over: ->(context) { context[:rooms] })
    D.workflow(name) do
      initial_state :idle
      state :failed
      budget(**budget) if budget
      transition :describe, from: :idle, to: :described do
        workflow child, over:, item_to: :room, concurrency: 2, output_to: :descriptions
        retry_on Smith::WorkflowError, attempts: 2, backoff: 30, durable: true if retried
        on_failure :fail
      end
    end
  end
  items("GoldenItemsWorkflow", GoldenItemChild)
  items("GoldenItemsRaisingWorkflow", GoldenItemRaisingChild)
  items("GoldenItemsNotArrayWorkflow", GoldenItemChild, over: ->(_context) { "a room" })
  items("GoldenItemsBudgetWorkflow", GoldenItemChild, budget: { total_cost: 1.0, total_tokens: 5000 })
  items("GoldenItemsTightWorkflow", GoldenItemChild, budget: { total_tokens: 130 })
  items("GoldenItemsRetriedWorkflow", GoldenItemChild, retried: true)
  D.workflow("GoldenItemsAwaitWorkflow") do
    initial_state :idle
    state :failed
    transition :wait, from: :idle, to: :ready do
      await :rooms_ready, into: :rooms, timeout: 3600
      on_failure :fail
    end
    transition :describe, from: :ready, to: :described do
      workflow GoldenItemChild, over: ->(context) { context[:rooms] }, item_to: :room, output_to: :descriptions
      on_failure :fail
    end
  end
  def self.rooms = { rooms: ["the kitchen", "the hall", "the porch"] }

  # Three replies, the second `middle`.
  def self.answering(run, middle, from: 1)
    run.reply(json: R.message("Warm.", id: "m#{from}")).reply(**middle)
       .reply(json: R.message("Open.", id: "m#{from + 2}"))
  end

  # 32. Items whose runs end refused, their failure routed and raised: each
  # that item's outcome. An item's run failing; no items; an `over:` that is
  # no Array; more items than the branch limit: the step fails.
  scenario(:items_outcomes) do |run|
    answering(run, { json: R.message("No.", id: "m2", stop: "refusal") })
    persisted(run, GoldenItemsWorkflow, "run-items-refused", context: rooms)
    answering(run, { json: R.message("No.", id: "m5", stop: "refusal") }, from: 4)
    persisted(run, GoldenItemsRaisingWorkflow, "run-items-raised", context: rooms)
    answering(run, { json: R.server_error, status: "500 Internal Server Error" }, from: 7)
    persisted(run, GoldenItemsWorkflow, "run-items-failed", context: rooms)
    settled(run)
    persisted(run, GoldenItemsWorkflow, "run-items-none", context: { rooms: [] })
    persisted(run, GoldenItemsNotArrayWorkflow, "run-items-bad", context: rooms)
    saved = Smith.config.parallel_branch_limit
    Smith.config.parallel_branch_limit = 2
    persisted(run, GoldenItemsWorkflow, "run-items-over", context: rooms)
  ensure
    Smith.config.parallel_branch_limit = saved
  end

  # 33. Items within the run's budget, and items whose run exceeds it.
  scenario(:items_budget) do |run|
    answering(run, { json: R.message("Long.", id: "m2") })
    persisted(run, GoldenItemsBudgetWorkflow, "run-items-budget", context: rooms)
    answering(run, { json: R.message("Long.", id: "m5") }, from: 4)
    persisted(run, GoldenItemsTightWorkflow, "run-items-tight", context: rooms)
  end

  # 34. An item's overload failing the step, its durable retry restored and
  # resumed; items after a durable wait, restored and resumed with them.
  scenario(:items_durable) do |run|
    answering(run, { json: R.overloaded, status: "529 Overloaded" })
    persisted(run, GoldenItemsRetriedWorkflow, "run-items-retry", context: rooms)
    settled(run)
    run.note(:expired, run.capture { run.expire(GoldenItemsRetriedWorkflow, "run-items-retry") })
    answering(run, { json: R.message("Long.", id: "m5") }, from: 4)
    resumed(run, GoldenItemsRetriedWorkflow, "run-items-retry")
    persisted(run, GoldenItemsAwaitWorkflow, "run-items-await")
    token = run.restore(GoldenItemsAwaitWorkflow, "run-items-await").awaiting.token
    run.note(:resumed, run.capture do
      GoldenItemsAwaitWorkflow.resume!("run-items-await", event: :rooms_ready, token:,
                                                          payload: ["the attic", "the cellar"], adapter: run.adapter)
    end)
    run.reply(json: R.message("Dusty.", id: "m7")).reply(json: R.message("Damp.", id: "m8"))
    resumed(run, GoldenItemsAwaitWorkflow, "run-items-await")
  end
end
