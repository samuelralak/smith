# frozen_string_literal: true

# Durable await and durable retry scenarios.
module CoreInvisibility
  # 17. A durable await, stored, delivered and run on.
  D.workflow("GoldenAwaitWorkflow") do
    initial_state :requested
    state :failed
    seed_messages { |_context| [{ role: :user, content: "Summarize the source." }] }
    transition :wait_source, from: :requested, to: :fetched do
      await :source_ready, into: :source, timeout: 3600
      on_failure :fail
    end
    transition :summarize, from: :fetched, to: :done do
      execute :golden_summary, output_to: :summary
      on_failure :fail
    end
  end
  scenario(:durable_await) do |run|
    run.reply(json: R.message("The source says 8.", id: "msg_a"))
    persisted(run, GoldenAwaitWorkflow, "run-await")
    token = run.restore(GoldenAwaitWorkflow, "run-await").awaiting.token
    run.note(:resumed, run.capture do
      GoldenAwaitWorkflow.resume!("run-await", event: :source_ready, token:, payload: { text: "Open at 8." },
                                               adapter: run.adapter)
    end)
    resumed(run, GoldenAwaitWorkflow, "run-await")
  end

  # 18. A durable retry after a server error.
  D.agent("GoldenRetryAgent", :golden_retry, prompt: "Answer briefly.")
  asking("GoldenRetryWorkflow", :golden_retry) { retry_on Smith::AgentError, attempts: 2, backoff: 30, durable: true }
  scenario(:durable_retry) do |run|
    run.reply(json: R.server_error, status: "500 Internal Server Error")
       .reply(json: R.message("Open at 8.", id: "msg_r"))
    persisted(run, GoldenRetryWorkflow, "run-retry")
    run.note(:expired, run.capture { run.expire(GoldenRetryWorkflow, "run-retry") })
    resumed(run, GoldenRetryWorkflow, "run-retry")
  end
end
