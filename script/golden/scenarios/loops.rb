# frozen_string_literal: true

# The optimize and orchestrate scenarios.
module CoreInvisibility
  # 8. optimize, rejected once and then accepted.
  D.agent("GoldenDraftAgent", :golden_draft, prompt: "Draft a notice.")
  D.agent("GoldenJudgeAgent", :golden_judge, prompt: "Judge the notice.")
  D.workflow("GoldenOptimizeWorkflow") do
    initial_state :idle
    state :failed
    seed_messages { |_context| [{ role: :user, content: "Write the opening hours notice." }] }
    transition :draft, from: :idle, to: :done do
      optimize generator: :golden_draft, evaluator: :golden_judge, max_rounds: 3,
               evaluator_schema: GoldenVerdictSchema
      on_failure :fail
    end
  end
  scenario(:optimize) do |run|
    run.reply(json: R.message("We open at eight in the morning, every day.", id: "msg_a"))
       .reply(json: R.json({ accept: false, feedback: "Shorter.", score: 0.4 }, id: "msg_b"))
       .reply(json: R.message("Open daily at 8.", id: "msg_c"))
       .reply(json: R.json({ accept: true, feedback: "Good.", score: 0.9 }, id: "msg_d"))
    persisted(run, GoldenOptimizeWorkflow, "run-optimize")
  end

  # 9. orchestrate, delegating to two workers. The orchestrator reads its
  # decision by Symbol keys, so the planner hands its parsed reply over
  # symbolized, as a host must; a worker's finding keeps its String keys.
  D.agent("GoldenPlannerAgent", :golden_planner, prompt: "Plan the research.") do
    output_schema GoldenDecisionSchema
    def after_completion(result, _context)
      result.is_a?(Hash) ? JSON.parse(JSON.generate(result), symbolize_names: true) : result
    end
  end
  D.agent("GoldenWorkerAgent", :golden_worker, prompt: "Do one task.")
  D.workflow("GoldenOrchestrateWorkflow") do
    initial_state :idle
    state :failed
    seed_messages { |_context| [{ role: :user, content: "Research the clinic." }] }
    transition :research, from: :idle, to: :done do
      orchestrate orchestrator: :golden_planner, worker: :golden_worker, max_workers: 2, max_delegation_rounds: 2,
                  task_schema: GoldenTaskSchema, worker_output_schema: GoldenFindingSchema,
                  final_output_schema: GoldenSummarySchema
      on_failure :fail
    end
  end
  scenario(:orchestrate) do |run|
    tasks = [{ task_id: "t1", input: "hours" }, { task_id: "t2", input: "address" }]
    run.reply(json: R.json({ tasks: }, id: "msg_a"))
       .reply(json: R.json({ finding: "Opens at 8." }, id: "msg_b"))
       .reply(json: R.json({ finding: "On Main Street." }, id: "msg_c"))
       .reply(json: R.json({ final: { summary: "Opens at 8 on Main Street." } }, id: "msg_d"))
    persisted(run, GoldenOrchestrateWorkflow, "run-orchestrate")
  end
end
