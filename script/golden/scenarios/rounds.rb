# frozen_string_literal: true

# orchestrate over the provider's own String-keyed replies, and a run of
# it restored after its process died part way.
module CoreInvisibility
  # 24. orchestrate as a host's planner gets its replies, with no
  # after_completion of its own: String keys throughout.
  D.agent("GoldenStringPlannerAgent", :golden_string_planner, prompt: "Plan the research.") do
    output_schema GoldenDecisionSchema
  end
  %w[GoldenStringOrchestrateWorkflow GoldenRoundsWorkflow].zip([2, 3]).each do |name, rounds|
    D.workflow(name) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "Research the clinic." }] }
      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :golden_string_planner, worker: :golden_worker, max_workers: 2,
                    max_delegation_rounds: rounds, task_schema: GoldenTaskSchema,
                    worker_output_schema: GoldenFindingSchema, final_output_schema: GoldenSummarySchema
        on_failure :fail
      end
    end
  end
  scenario(:orchestrate_string_keys) do |run|
    tasks = [{ task_id: "t1", input: "hours" }, { task_id: "t2", input: "address" }]
    run.reply(json: R.json({ tasks: }, id: "msg_a"))
       .reply(json: R.json({ finding: "Opens at 8." }, id: "msg_b"))
       .reply(json: R.json({ finding: "On Main Street." }, id: "msg_c"))
       .reply(json: R.json({ final: { summary: "Opens at 8 on Main Street." } }, id: "msg_d"))
    persisted(run, GoldenStringOrchestrateWorkflow, "run-orchestrate-strings")
  end

  # Each round's decision, by the round its request names, and each
  # worker's finding, by its task: a request sent again gets the same reply.
  ROUNDS = {
    "1" => { tasks: [{ task_id: "t1", input: "hours" }, { task_id: "t2", input: "address" }] },
    "2" => { tasks: [{ task_id: "t1", input: "hours" }] },
    "3" => { final: { summary: "Opens at 8 on Main Street." } }
  }.freeze

  def self.round_reply(request)
    text = request.body.fetch("messages").last.fetch("content").sum("") { _1["text"].to_s }
    return R.json({ finding: "Found the #{JSON.parse(text).fetch("input")}." }, id: "msg_w") if text.start_with?("{")

    round = text[/\A\[smith:orchestration-round\] (\d)/, 1] || "1"
    R.json(ROUNDS.fetch(round), id: "msg_r#{round}")
  end

  # 25. Three rounds, the process killed once the memo keeps round 2's
  # decision (its fourth call), then restored and run on: the restored run
  # asks round 2 what it asked before, so every kept call replays.
  scenario(:orchestrate_restored) do |run|
    memo = Smith.config.response_memo = Hosts::Memo.new
    memo.crash_on = true
    memo.crash_after = 4
    run.server.answer { { json: round_reply(_1) } }
    persisted(run, GoldenRoundsWorkflow, "run-rounds")
    resumed(run, GoldenRoundsWorkflow, "run-rounds")
  end
end
