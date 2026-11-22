# frozen_string_literal: true

# Steps that end failed, so the golden holds their failure records, and an
# image's refusal taken by its fallback.
module CoreInvisibility
  # 21. An image agent whose answer holds no image: an output failure whose
  # usage is kept, failing its step.
  scenario(:image_unkept) do |run|
    Smith.config.pricing = PRICES.merge(IMAGE_PRICES)
    run.reply(json: R.painted(DRAWN).merge("data" => [{ "url" => nil }]))
    persisted(run, GoldenPaintWorkflow, "run-paint-unkept")
  end

  # 22. A moderation block, a refusal its agent's on_refusal takes to a
  # fallback that paints.
  D.agent("GoldenGuardedPaintAgent", :golden_guarded_paint, model_id: "gpt-image-test", provider: :openai,
                                                            prompt: "Draw it in blue ballpoint.") do
    image size: "1024x1024", quality: "low", background: "opaque"
    on_refusal fallback: "openai/gpt-image-other"
  end
  drawing("GoldenGuardedPaintWorkflow", :golden_guarded_paint)
  scenario(:image_refusal_fallback) do |run|
    Smith.config.pricing = PRICES.merge(IMAGE_PRICES)
    run.reply(json: R.moderation_blocked, status: "400 Bad Request").reply(json: R.painted(DRAWN))
    persisted(run, GoldenGuardedPaintWorkflow, "run-paint-refused")
  end

  # 23. An output that fails its schema again after its repair, failing its
  # step.
  scenario(:repair_exhausted) do |run|
    run.reply(json: R.message("It is a bug.", id: "msg_a"))
       .reply(json: R.message("Still a bug.", id: "msg_b"))
    persisted(run, GoldenRepairWorkflow, "run-repair-exhausted")
  end
end
