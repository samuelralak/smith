# frozen_string_literal: true

# Streamed, batch, fallback and repair scenarios.
module CoreInvisibility
  # 10. A streamed step.
  D.agent("GoldenStreamAgent", :golden_stream, prompt: "Answer briefly.")
  asking("GoldenStreamWorkflow", :golden_stream, stream: :reply)
  scenario(:streamed) do |run|
    Smith.config.stream_sinks = { reply: Hosts::Sink.opener }
    run.reply(events: R.streamed(["Open ", "at 8."], id: "msg_s"))
    persisted(run, GoldenStreamWorkflow, "run-stream")
  end

  # 11. A batch step, captured and then delivered.
  D.agent("GoldenBatchAgent", :golden_batch, prompt: "Classify the review.")
  asking("GoldenBatchWorkflow", :golden_batch, mode: :batch, ask: "Great service.")
  scenario(:batch) do |run|
    queue = Smith.config.batch_queue = Hosts::BatchQueue.new
    persisted(run, GoldenBatchWorkflow, "run-batch")
    token = run.restore(GoldenBatchWorkflow, "run-batch").awaiting.token
    payload = queue.items.to_h { [_1[:custom_id], R.succeeded("positive", id: "msg_b", tokens: [5, 2])] }
    run.capture do
      GoldenBatchWorkflow.resume!("run-batch", event: :batch_result, token:, payload:, adapter: run.adapter)
    end
    run.finish(run.restore(GoldenBatchWorkflow, "run-batch"))
  end

  # 12. A fallback after the first model answers 529.
  D.agent("GoldenFallbackAgent", :golden_fallback, prompt: "Answer briefly.") do
    fallback_models model: "claude-haiku-5-5", provider: :anthropic
  end
  asking("GoldenFallbackWorkflow", :golden_fallback)
  scenario(:fallback_after_overload) do |run|
    run.reply(json: R.overloaded, status: "529 Overloaded")
       .reply(json: R.message("Open at 8.", id: "msg_h", model: "claude-haiku-5-5"))
    persisted(run, GoldenFallbackWorkflow, "run-fallback")
  end

  # 13. An output repair after an invalid reply.
  D.agent("GoldenRepairAgent", :golden_repair, prompt: "Label the ticket.") { output_schema GoldenLabelSchema }
  asking("GoldenRepairWorkflow", :golden_repair, into: :label, ask: "The page is blank.")
  scenario(:output_repair) do |run|
    run.reply(json: R.message("It is a bug.", id: "msg_a"))
       .reply(json: R.json({ label: "bug" }, id: "msg_b"))
    persisted(run, GoldenRepairWorkflow, "run-repair")
  end
end
