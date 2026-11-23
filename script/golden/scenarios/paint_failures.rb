# frozen_string_literal: true

# Every way a paint can fail or be refused that the image scenarios above do
# not reach (slice 016, from its review's scenarios).
module CoreInvisibility
  D.agent("GoldenFallbackPaintAgent", :golden_fallback_paint, model_id: "gpt-image-test", provider: :openai,
                                                              prompt: "Draw it.") do
    image size: "1024x1024", quality: "low", background: "opaque"
    fallback_models model: "gpt-image-other", provider: :openai
  end
  D.agent("GoldenLonePaintAgent", :golden_lone_paint, model_id: "gpt-image-test", provider: :openai,
                                                      prompt: "Draw.") do
    image size: "1024x1024", quality: "low", output_format: "webp"
  end
  drawing("GoldenFallbackPaintWorkflow", :golden_fallback_paint)
  drawing("GoldenLonePaintWorkflow", :golden_lone_paint)

  # A paint's first answer, as the provider sends it.
  ANSWERED_ERRORS = {
    server_error: ["500 Internal Server Error", R.server_error],
    gateway_timeout: ["504 Gateway Timeout", { "error" => { "message" => "Gateway timeout" } }],
    unauthorized: ["401 Unauthorized", { "error" => { "message" => "bad key", "type" => "invalid_request_error" } }],
    forbidden: ["403 Forbidden", { "error" => { "message" => "no access" } }],
    model_missing: ["404 Not Found", { "error" => { "message" => "no such model" } }],
    overloaded: ["529 Overloaded", R.overloaded],
    bad_request: ["400 Bad Request", { "error" => { "code" => "other", "message" => "bad" } }]
  }.freeze

  def self.paint_prices = Smith.config.pricing = PRICES.merge(IMAGE_PRICES)

  # Each run's replies left unused, dropped before the next run.
  def self.settled(run)
    run.note(:unused_replies, run.server.pending_replies)
    run.server.clear_replies
  end

  # 26. A paint answered with an error, its fallback waiting: only a refusal
  # of the account, the model or the content goes to it.
  scenario(:image_answered_errors) do |run|
    paint_prices
    ANSWERED_ERRORS.each do |name, (status, body)|
      run.reply(json: body, status:).reply(json: R.painted(DRAWN))
      persisted(run, GoldenFallbackPaintWorkflow, "run-#{name}")
      settled(run)
    end
  end

  # 27. Throttled on its model and on its fallback; the connection lost once
  # sent; a moderation block with no refusal fallback; an empty list of
  # images; and an image the artifact store fails to keep.
  scenario(:image_failures) do |run|
    paint_prices
    run.reply(json: R.throttled, status: "429 Too Many Requests")
       .reply(json: R.throttled, status: "429 Too Many Requests")
    persisted(run, GoldenFallbackPaintWorkflow, "run-throttled-twice")
    run.reply(drop: true).reply(json: R.painted(DRAWN))
    persisted(run, GoldenFallbackPaintWorkflow, "run-dropped")
    settled(run)
    run.reply(json: R.moderation_blocked, status: "400 Bad Request")
    persisted(run, GoldenLonePaintWorkflow, "run-refused")
    run.reply(json: R.painted(DRAWN).merge("data" => []))
    persisted(run, GoldenLonePaintWorkflow, "run-no-data")
    failing = Class.new(Hosts::Artifacts) do
      def store(data, **)
        raise IOError, "the store is full" if data == DRAWN

        super
      end
    end
    Smith.config.artifact_store = failing.new
    run.reply(json: R.painted(DRAWN))
    persisted(run, GoldenLonePaintWorkflow, "run-store-fails")
  end
end
