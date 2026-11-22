# frozen_string_literal: true

# Nested workflow and inline child run scenarios.
module CoreInvisibility
  # 6. A nested workflow, then a step of the parent's own.
  D.agent("GoldenChildAgent", :golden_child, prompt: "Research the topic.")
  D.agent("GoldenSummaryAgent", :golden_summary, prompt: "Summarize what was found.")
  D.workflow("GoldenNestedChildWorkflow") do
    initial_state :idle
    seed_messages { |_context| [{ role: :user, content: "Research the clinic." }] }
    transition :research, from: :idle, to: :done do
      execute :golden_child
    end
  end
  D.workflow("GoldenNestedWorkflow") do
    initial_state :idle
    state :failed
    seed_messages { |_context| [{ role: :user, content: "Find out about the clinic." }] }
    transition :research, from: :idle, to: :researched do
      workflow GoldenNestedChildWorkflow
      on_failure :fail
    end
    transition :summarize, from: :researched, to: :done do
      execute :golden_summary, output_to: :summary
      on_failure :fail
    end
  end
  scenario(:nested_workflow) do |run|
    run.reply(json: R.message("The clinic opens at 8.", id: "msg_a"))
       .reply(json: R.message("It opens at 8.", id: "msg_b"))
    persisted(run, GoldenNestedWorkflow, "run-nested")
  end

  # 7. An inline `call` child, then a step of the parent's own. The child
  # runs apart from the parent's attribution, so a trial does not follow it.
  D.agent("GoldenCallAgent", :golden_call, prompt: "Answer for the child run.")
  D.workflow("GoldenCallChildWorkflow") do
    initial_state :idle
    seed_messages { |context| [{ role: :user, content: "Look into #{context[:topic]}." }] }
    transition :look, from: :idle, to: :done do
      execute :golden_call
    end
  end
  D.workflow("GoldenCallWorkflow") do
    initial_state :idle
    state :failed
    seed_messages { |_context| [{ role: :user, content: "Report on the clinic." }] }
    transition :delegate, from: :idle, to: :delegated do
      call GoldenCallChildWorkflow, input: ->(context) { { topic: context[:topic] } }, timeout: 60, into: :child
      on_failure :fail
    end
    transition :summarize, from: :delegated, to: :done do
      execute :golden_summary, output_to: :summary
      on_failure :fail
    end
  end
  scenario(:inline_call_child) do |run|
    Smith.config.run_launcher = Smith::Launchers::Inline.new
    run.reply(json: R.message("The child found the hours.", id: "msg_a"))
       .reply(json: R.message("It opens at 8.", id: "msg_b"))
    persisted(run, GoldenCallWorkflow, "run-call", context: { topic: "the clinic" })
  end
end
