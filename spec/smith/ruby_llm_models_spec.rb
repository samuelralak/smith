# frozen_string_literal: true

RSpec.describe "Smith RubyLLM model registry extensions" do
  it "registers Claude Opus 4.7 with RubyLLM" do
    model = RubyLLM.models.find("claude-opus-4-7", :anthropic)

    expect(model.name).to eq("Claude Opus 4.7")
    expect(model.provider).to eq("anthropic")
    expect(model.family).to eq("claude-opus")
    expect(model.context_window).to eq(1_000_000)
    expect(model.max_output_tokens).to eq(128_000)
    expect(model.supports_functions?).to be(true)
    expect(model.supports_vision?).to be(true)
    expect(model.reasoning?).to be(true)
    expect(model.input_price_per_million).to eq(5.0)
    expect(model.output_price_per_million).to eq(25.0)
  end

  it "does not duplicate the model when installation runs more than once" do
    expect { Smith::RubyLLMModels.install! }.not_to change { opus_4_7_count }
  end

  it "renders Claude Opus 4.7 thinking with Anthropic's adaptive payload shape" do
    payload = anthropic_payload(thinking: RubyLLM::Thinking::Config.new(budget: 16_384))

    expect(payload[:thinking]).to eq(type: "adaptive")
    expect(payload[:thinking]).not_to include(:budget_tokens)
    expect(payload.dig(:output_config, :effort)).to eq("high")
  end

  it "preserves explicit adaptive effort when one is configured" do
    payload = anthropic_payload(thinking: RubyLLM::Thinking::Config.new(effort: "xhigh"))

    expect(payload[:thinking]).to eq(type: "adaptive")
    expect(payload.dig(:output_config, :effort)).to eq("xhigh")
  end

  it "keeps structured-output config when adding adaptive effort" do
    payload = anthropic_payload(
      thinking: RubyLLM::Thinking::Config.new(budget: 16_384),
      schema: {
        schema: {
          type: "object",
          properties: { answer: { type: "string" } },
          required: ["answer"],
          strict: true
        }
      }
    )

    expect(payload[:thinking]).to eq(type: "adaptive")
    expect(payload[:output_config]).to eq(
      format: {
        type: "json_schema",
        schema: {
          type: "object",
          properties: { answer: { type: "string" } },
          required: ["answer"]
        }
      },
      effort: "high"
    )
  end

  it "omits sampling temperature for Claude Opus 4.7" do
    payload = anthropic_payload(
      thinking: RubyLLM::Thinking::Config.new(budget: 16_384),
      temperature: 1.0
    )

    expect(payload).not_to include(:temperature)
  end

  def opus_4_7_count
    RubyLLM.models.all.count do |model|
      model.id == "claude-opus-4-7" && model.provider == "anthropic"
    end
  end

  # Mirrors production: `complete` (Provider instance method) calls
  # `render_payload` on `self`, and the Anthropic class includes
  # `Anthropic::Chat` to gain that method as an instance method. Driving
  # this helper through a provider instance — not through
  # `Chat.render_payload(...)` (the module-function path) — ensures the
  # adaptive-thinking compat shim is exercised by the same dispatch path
  # used at runtime. The previous helper invoked the module-function
  # path, which is why the specs passed while production silently
  # bypassed the shim.
  def anthropic_payload(thinking:, schema: nil, temperature: nil)
    config = RubyLLM.config.dup
    config.anthropic_api_key = "test-anthropic-key"
    provider = RubyLLM::Providers::Anthropic.new(config)
    provider.render_payload(
      [RubyLLM::Message.new(role: :user, content: "Hello")],
      tools: {},
      temperature: temperature,
      model: RubyLLM.models.find("claude-opus-4-7", :anthropic),
      schema: schema,
      thinking: thinking
    )
  end
end
