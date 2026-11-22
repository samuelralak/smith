# frozen_string_literal: true

# Budget ledger, response memo and budget pause scenarios.
module CoreInvisibility
  class << self
    # The host ledger the budget scenarios' workflows hold their requests on.
    attr_accessor :ledger
  end

  # 14. A step held on a budget_ledger.
  D.agent("GoldenLedgerAgent", :golden_ledger, prompt: "Answer briefly.")
  D.workflow("GoldenLedgerWorkflow") do
    initial_state :idle
    state :failed
    budget_ledger { |_scope| CoreInvisibility.ledger }
    seed_messages { |_context| [{ role: :user, content: "Is the clinic open?" }] }
    transition :ask, from: :idle, to: :done do
      execute :golden_ledger, output_to: :answer
      on_failure :fail
    end
  end
  scenario(:budget_ledger) do |run|
    self.ledger = Hosts::Ledger.new
    run.reply(json: R.message("Open at 8.", id: "msg_l"))
    persisted(run, GoldenLedgerWorkflow, "run-ledger")
  end

  # 15. A response memo replays a step killed after its call was kept.
  D.agent("GoldenMemoAgent", :golden_memo, prompt: "Answer briefly.")
  asking("GoldenMemoWorkflow", :golden_memo)
  scenario(:memo_replay) do |run|
    memo = Smith.config.response_memo = Hosts::Memo.new
    memo.crash_on = true
    run.reply(json: R.message("Kept answer.", tokens: [40, 9]))
    persisted(run, GoldenMemoWorkflow, "run-memo")
    resumed(run, GoldenMemoWorkflow, "run-memo")
  end

  # 16. A tool loop paused for budget, continued after the durable retry.
  D.agent("GoldenPauseAgent", :golden_pause, prompt: "Find the hours.") { tools GoldenLookup }
  D.workflow("GoldenPauseWorkflow") do
    initial_state :idle
    state :failed
    budget_ledger { |_scope| CoreInvisibility.ledger }
    seed_messages { |_context| [{ role: :user, content: "Find the hours." }] }
    transition :ask, from: :idle, to: :done do
      execute :golden_pause, output_to: :answer
      retry_on Smith::BudgetUnavailable, attempts: 3, backoff: 60, durable: true
      on_failure :fail
    end
  end
  scenario(:budget_pause) do |run|
    topped = false
    self.ledger = Hosts::Ledger.new(admit: ->(count) { count != 2 || topped })
    run.reply(json: R.calling("golden_lookup", id: "toolu_1", input: { "query" => "clinic" }, msg: "msg_a"))
       .reply(json: R.message("Open 8 to 6.", id: "msg_b", tokens: [40, 6]))
    persisted(run, GoldenPauseWorkflow, "run-pause")
    topped = true
    run.note(:expired, run.capture { run.expire(GoldenPauseWorkflow, "run-pause") })
    resumed(run, GoldenPauseWorkflow, "run-pause")
  end
end
