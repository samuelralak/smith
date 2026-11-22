# frozen_string_literal: true

# An agent answering with an image (0.16.0): its attempt paints, through
# OpenAI's image edits, instead of chatting.
module CoreInvisibility
  IMAGE_PRICES = %w[gpt-image-test gpt-image-other].to_h do |model|
    [["openai", model], { input_cost_per_token: 0.000005, output_cost_per_token: 0.00003,
                          image_input_cost_per_token: 0.000008, image_output_cost_per_token: 0.00003,
                          image_output_tokens: { "1024x1024" => { "low" => 823 } } }]
  end.freeze
  GUIDE = "\x89PNG\r\n\x1A\nguide".b.freeze
  DRAWN = "\x89PNG\r\n\x1A\ndrawn".b.freeze

  # 19. An image agent drawing from a guide the run keeps: once on its own
  # model, and once more after that model is throttled, on its fallback.
  D.agent("GoldenPaintAgent", :golden_paint, model_id: "gpt-image-test", provider: :openai,
                                             prompt: "Draw it in blue ballpoint.") do
    image size: "1024x1024", quality: "low", background: "opaque"
    fallback_models model: "gpt-image-other", provider: :openai
  end
  # Keeps a guide image, then has `agent` draw from it.
  def self.drawing(name, agent)
    D.workflow(name) do
      initial_state :idle
      state :failed
      transition :keep, from: :idle, to: :kept do
        compute { |step| step.write_context(:guide, Smith.artifacts.store(GUIDE, content_type: "image/png")) }
      end
      transition :draw, from: :kept, to: :done do
        execute agent, output_to: :drawn, input: lambda { |context|
          [Smith::Message.user([Smith::Content.text("The pose: standing tall."),
                                Smith::Content.image(context[:guide], media_type: "image/png")])]
        }
        on_failure :fail
      end
    end
  end
  drawing("GoldenPaintWorkflow", :golden_paint)
  scenario(:image_answer) do |run|
    Smith.config.pricing = PRICES.merge(IMAGE_PRICES)
    run.reply(json: R.painted(DRAWN))
    persisted(run, GoldenPaintWorkflow, "run-paint")
    run.reply(json: R.throttled, status: "429 Too Many Requests").reply(json: R.painted(DRAWN))
    persisted(run, GoldenPaintWorkflow, "run-paint-fallback")
  end
end
