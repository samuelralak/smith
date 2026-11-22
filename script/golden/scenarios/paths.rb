# frozen_string_literal: true

# Serial, tool loop, parallel, fan-out and route scenarios.
module CoreInvisibility
  # 1. Serial, with an output schema.
  D.agent("GoldenLabelAgent", :golden_label, prompt: "Label the ticket.") { output_schema GoldenLabelSchema }
  asking("GoldenSerialWorkflow", :golden_label, into: :label, ask: "The app crashes on login.")
  scenario(:serial_output_schema) do |run|
    run.reply(json: R.json({ label: "bug" }))
    persisted(run, GoldenSerialWorkflow, "run-serial", context: { ticket: "t-1" })
  end

  # 2. A tool loop of two rounds.
  D.agent("GoldenToolAgent", :golden_tool, prompt: "Find the hours.") { tools GoldenLookup }
  asking("GoldenToolLoopWorkflow", :golden_tool)
  scenario(:tool_loop) do |run|
    run.reply(json: R.calling("golden_lookup", id: "toolu_1", input: { "query" => "clinic" }, msg: "msg_a"))
       .reply(json: R.calling("golden_lookup", id: "toolu_2", input: { "query" => "pharmacy" }, msg: "msg_b"))
       .reply(json: R.message("Both open at 8.", id: "msg_c", tokens: [30, 6]))
    persisted(run, GoldenToolLoopWorkflow, "run-tools")
  end

  # 3. parallel: true, three branches.
  D.agent("GoldenFindingAgent", :golden_finding, prompt: "Find one fact.")
  D.workflow("GoldenParallelWorkflow") do
    initial_state :idle
    state :failed
    seed_messages { |_context| [{ role: :user, content: "Research the clinic." }] }
    transition :find, from: :idle, to: :done do
      execute :golden_finding, parallel: true, count: 3
      on_failure :fail
    end
  end
  scenario(:parallel_branches, concurrent: true) do |run|
    run.server.answer { D.by_request(_1) }
    workflow = GoldenParallelWorkflow.new(context: {})
    run.finish(workflow, run.capture { workflow.run! })
  end

  # 4. fan_out over three agents.
  { left: "Read the left page.", middle: "Read the middle page.", right: "Read the right page." }.each do |key, ask|
    D.agent("GoldenFan#{key.capitalize}Agent", :"golden_fan_#{key}", prompt: ask)
  end
  D.workflow("GoldenFanOutWorkflow") do
    initial_state :idle
    state :failed
    seed_messages { |_context| [{ role: :user, content: "Read the report." }] }
    transition :read, from: :idle, to: :done do
      fan_out branches: { left: :golden_fan_left, middle: :golden_fan_middle, right: :golden_fan_right }
      on_failure :fail
    end
  end
  scenario(:fan_out, concurrent: true) do |run|
    run.server.answer { D.by_request(_1) }
    persisted(run, GoldenFanOutWorkflow, "run-fan-out")
  end

  # 5. route, then the chosen specialist.
  D.agent("GoldenTriageAgent", :golden_triage, prompt: "Route the ticket.") { output_schema GoldenRouteSchema }
  D.agent("GoldenRefundAgent", :golden_refund, prompt: "Handle the refund.")
  D.workflow("GoldenRouteWorkflow") do
    initial_state :idle
    state :failed
    seed_messages { |_context| [{ role: :user, content: "I want my money back." }] }
    transition :classify, from: :idle, to: :triaged do
      route :golden_triage, routes: { refund: :handle_refund, support: :handle_support },
                            confidence_threshold: 0.75, fallback: :handle_support
      on_failure :fail
    end
    transition :handle_refund, from: :triaged, to: :refunded do
      execute :golden_refund, output_to: :reply
      on_failure :fail
    end
    transition :handle_support, from: :triaged, to: :supported
  end
  scenario(:route) do |run|
    run.reply(json: R.json({ route: "refund", confidence: 0.9 }, id: "msg_a"))
       .reply(json: R.message("Your refund is on its way.", id: "msg_b"))
    persisted(run, GoldenRouteWorkflow, "run-route")
  end
end
