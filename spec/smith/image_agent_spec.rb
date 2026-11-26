# frozen_string_literal: true

require "base64"

# An image agent (0.16.0) paints instead of chatting: its prompt and images go
# to the provider's image edits as one multipart request, held on the run's
# budget ledger at the image its size and quality write, and its answer is the
# image, kept as an artifact. A moderation block is a refusal; a request sent
# whose answer never came is never sent again.
RSpec.describe "Smith image agents" do
  pose = lambda do |context|
    [Smith::Message.user([Smith::Content.text("The pose: standing tall."),
                          Smith::Content.image(context[:guide], media_type: "image/png")])]
  end
  before do
    stub_const("POSE", pose)
    stub_const("GUIDE", guide)
  end

  include_context "with a recording budget ledger"

  let(:guide) { "\x89PNG\r\n\x1A\n".b + "guide".b }
  let(:drawn) { "\x89PNG\r\n\x1A\n".b + "drawn".b }
  let(:image_prices) do
    { input_cost_per_token: 0.000005, output_cost_per_token: 0.00003, image_input_cost_per_token: 0.000008,
      image_output_cost_per_token: 0.00003, image_output_tokens: { "1024x1024" => { "low" => 823 } } }
  end
  let(:usage) do
    { "input_tokens" => 400, "input_tokens_details" => { "image_tokens" => 323, "text_tokens" => 77 },
      "output_tokens" => 823, "output_tokens_details" => { "image_tokens" => 823, "text_tokens" => 0 },
      "total_tokens" => 1223 }
  end
  let(:painted) { { "created" => 1, "data" => [{ "b64_json" => Base64.strict_encode64(drawn) }], "usage" => usage } }
  let(:blocked) do
    { "error" => { "code" => "moderation_blocked", "type" => "image_generation_user_error",
                   "message" => "Your request was rejected by the safety system." } }
  end

  around do |example|
    saved = RubyLLM.config.retry_interval
    example.run
  ensure
    RubyLLM.config.retry_interval = saved
  end

  before do
    Smith.config.pricing = Smith.config.pricing.merge(%w[openai gpt-image-test] => image_prices,
                                                      %w[openai gpt-image-other] => image_prices)
    RubyLLM.config.retry_interval = 0
  end

  def image_agent(name, register: :spec_image_agent, &body)
    Smith::Agent::Registry.delete(register)
    klass = with_stubbed_class(name, agent_class) do
      register_as register
      model "gpt-image-test", provider: :openai, assume_model_exists: true
      image size: "1024x1024", quality: "low", background: "opaque"
      instructions "Draw it in blue ballpoint."
    end
    klass.class_exec(&body) if body
    klass
  end

  def drawing(name, **step)
    built = ledger
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :stored
      state :done
      state :failed
      budget_ledger { |_scope| built }
      transition :store, from: :idle, to: :stored do
        compute { |step| step.write_context(:guide, Smith.artifacts.store(GUIDE, content_type: "image/png")) }
      end
      transition :draw, from: :stored, to: :done do
        execute :spec_image_agent, input: POSE, output_to: :drawn, **step
        on_failure :fail
      end
    end
  end

  def run(workflow_class) = workflow_class.new(context: {}).run!

  def failure(result) = result.steps.find { _1.key?(:error) }&.fetch(:error)

  it "paints from its instructions, its text and its images, once, and answers the image as an artifact" do
    image_agent("SpecPaintAgent")
    server.reply(json: painted)
    result = run(drawing("SpecPaintWorkflow"))
    sent = server.requests.sole
    part = result.context[:drawn]

    expect(result.state).to eq(:done)
    expect(sent.path).to eq("/v1/images/edits")
    expect(sent.body).to include("name=\"model\"\r\n\r\ngpt-image-test", "name=\"size\"\r\n\r\n1024x1024",
                                 "name=\"quality\"\r\n\r\nlow", "name=\"background\"\r\n\r\nopaque",
                                 "name=\"output_format\"\r\n\r\npng", "name=\"image[]\"", "guide")
    expect(sent.body[/name="prompt"\r\n\r\n(.*?)\r\n--/m, 1])
      .to start_with("Draw it in blue ballpoint.").and include("The pose: standing tall.")
    expect(part).to include(type: "image", media_type: "image/png")
    expect(Smith.artifact_backend.fetch(part[:artifact].split(":", 2).last)).to eq(drawn)
  end

  it "paints from a named prompt as the run sends it, a trial's candidate here, and stamps its version" do
    image_agent("SpecPromptedPaintAgent") do
      inputs :ink
      instructions Smith::Prompt.new("paint.style", "Draw it in {{ink}} ballpoint.")
    end
    server.reply(json: painted)
    saved = Smith.config.trace_adapter
    Smith.config.trace_adapter = traces = Smith::Trace::Memory.new
    candidate = "Sketch it in {{ink}} ink."
    workflow = Smith::Prompts.with_candidate("paint.style" => candidate) do
      drawing("SpecPromptedPaintWorkflow").new(context: { ink: "red" }).tap(&:run!)
    end
    stamp = [{ id: "paint.style", version: "sha256:#{Digest::SHA256.hexdigest(candidate)}" }]

    expect(server.requests.sole.body[/name="prompt"\r\n\r\n(.*?)\r\n--/m, 1]).to start_with("Sketch it in red ink.")
    expect(workflow.usage_entries.sole.components).to eq(stamp)
    expect(traces.traces.select { _1[:type] == :provider_call }.map { _1[:data][:components] }).to eq([stamp])
  ensure
    Smith.config.trace_adapter = saved
  end

  it "stamps a paint it could not keep with its prompt's version, and one whose chat failed to build with none" do
    text = "Draw it in {{ink}} ballpoint."
    image_agent("SpecPromptedUnkeptAgent") do
      inputs :ink
      instructions Smith::Prompt.new("paint.style", text)
    end
    server.reply(json: painted.merge("data" => [{ "url" => nil }]))
    saved = Smith.config.trace_adapter
    Smith.config.trace_adapter = traces = Smith::Trace::Memory.new
    unkept = drawing("SpecPromptedUnkeptWorkflow").new(context: { ink: "red" }).run!
    missing = drawing("SpecPromptedMissingWorkflow").new(context: {}).run!
    stamp = [{ id: "paint.style", version: "sha256:#{Digest::SHA256.hexdigest(text)}" }]

    expect(unkept.usage_entries.sole.to_h).to include(attempt_kind: :partial_attempt, components: stamp)
    expect(failure(missing)).to be_a(Smith::TemplateValueMissing)
    expect(traces.traces.select { _1[:type] == :provider_call }.map { _1[:data][:components] }).to eq([stamp, nil])
    expect(server.requests.size).to eq(1)
  ensure
    Smith.config.trace_adapter = saved
  end

  it "counts and prices the image parts of its input and output apart" do
    image_agent("SpecPricedAgent")
    server.reply(json: painted)
    entry = run(drawing("SpecPricedWorkflow")).usage_entries.sole
    cost = (77 * 0.000005) + (323 * 0.000008) + (823 * 0.00003)

    expect(entry.to_h).to include(input_tokens: 400, output_tokens: 823, image_input_tokens: 323,
                                  image_output_tokens: 823)
    expect(entry.cost).to be_within(1e-12).of(cost)
  end

  it "holds the image its size and quality write before sending, and settles what it cost" do
    image_agent("SpecHeldAgent")
    server.reply(json: painted)
    result = run(drawing("SpecHeldWorkflow"))
    (_, key, hold), (_, settled_key, spent) = ledger.calls

    expect(ledger.kinds).to eq(%i[reserve reconcile])
    # Held under the attempt's own id, the one its usage is recorded under.
    expect([key, settled_key]).to eq(["#{result.usage_entries.sole.attempt_id}:1"] * 2)
    expect([hold.output_tokens, hold.input_tokens]).to eq([823, hold.input_tokens])
    expect(hold.input_tokens).to be > Smith::Budget::RequestHold::IMAGE_TOKENS
    expect(hold.cost).to be > 823 * 0.00003
    expect(spent.cost).to be_within(1e-12).of((77 * 0.000005) + (323 * 0.000008) + (823 * 0.00003))
  end

  it "refuses to hold an image whose size and quality the catalog prices not, so nothing is sent" do
    image_agent("SpecUnpricedAgent") { image size: "1024x1536", quality: "low" }
    built = ledger_class.new(admit: ->(amount) { !amount.cost.nil? })
    allow(ledger_class).to receive(:new).and_return(built)
    result = run(drawing("SpecUnpricedWorkflow"))

    expect(failure(result)).to be_a(Smith::BudgetUnavailable)
    expect(server.requests).to be_empty
  end

  it "takes a moderation block as a refusal, costing nothing and never sent again" do
    image_agent("SpecBlockedAgent")
    server.reply(json: blocked, status: "400 Bad Request")
    result = run(drawing("SpecBlockedWorkflow"))

    expect(failure(result)).to be_a(Smith::OutputRefused)
    expect(failure(result).stop_reason).to eq("moderation_blocked")
    expect(ledger.kinds).to eq(%i[reserve release])
    expect(server.requests.size).to eq(1)
  end

  it "never sends again a request whose answer timed out, to its model or a fallback, and charges its hold" do
    slow = RubyLLM.context { |config| config.request_timeout = 0.3 }
    image_agent("SpecTimedOutAgent") do
      context slow
      fallback_models "openai/gpt-image-other"
    end
    server.reply(json: painted, after: 1.5)
    server.reply(json: painted)
    result = run(drawing("SpecTimedOutWorkflow"))
    (_, _, hold), (_, _, charged) = ledger.calls

    expect(failure(result)).to be_a(Smith::RequestOutcomeUncertain)
    expect(failure(result).cause).to be_a(Faraday::TimeoutError)
    expect(Smith::Errors.retry_forbidden?(failure(result))).to be(true)
    expect(ledger.kinds).to eq(%i[reserve reconcile])
    expect(charged).to eq(hold)
    expect(server.requests.size).to eq(1)
  end

  it "takes a connection lost once the request was sent as an outcome it cannot know" do
    image_agent("SpecDroppedAgent")
    server.reply(drop: true)
    result = run(drawing("SpecDroppedWorkflow"))

    expect(failure(result)).to be_a(Smith::RequestOutcomeUncertain)
    expect(ledger.kinds).to eq(%i[reserve reconcile])
    expect(server.requests.size).to eq(1)
  end

  it "never sends again a request a server answered with an error, though RubyLLM would retry and a fallback waits" do
    RubyLLM.config.max_retries = 3
    image_agent("SpecServerErrorAgent") { fallback_models "openai/gpt-image-other" }
    server.reply(json: { "error" => { "message" => "Internal" } }, status: "500 Internal Server Error")
    server.reply(json: painted)
    result = run(drawing("SpecServerErrorWorkflow"))

    expect(failure(result)).to be_a(Smith::ProviderPermanentFailure)
    expect(Smith::Errors.retryable?(failure(result))).to be(false)
    expect([server.requests.size, ledger.kinds]).to eq([1, %i[reserve release]])
  end

  it "sends a throttled request to the fallback" do
    image_agent("SpecThrottledAgent") { fallback_models "openai/gpt-image-other" }
    server.reply(json: { "error" => { "message" => "Slow down" } }, status: "429 Too Many Requests")
    server.reply(json: painted)
    result = run(drawing("SpecThrottledWorkflow"))

    expect(result.state).to eq(:done)
    expect(server.requests.map { _1.body[/name="model"\r\n\r\n([^\r]+)/, 1] }).to eq(%w[gpt-image-test gpt-image-other])
  end

  it "takes a gateway's timeout as an outcome it cannot know, charging the hold" do
    image_agent("SpecGatewayAgent") { fallback_models "openai/gpt-image-other" }
    server.reply(json: { "error" => { "message" => "Gateway timeout" } }, status: "504 Gateway Timeout")
    result = run(drawing("SpecGatewayWorkflow"))
    (_, _, hold), (_, _, charged) = ledger.calls

    expect(failure(result)).to be_a(Smith::RequestOutcomeUncertain)
    expect(charged).to eq(hold)
    expect(server.requests.size).to eq(1)
  end

  it "paints the refusal's fallback, never a chat request" do
    image_agent("SpecRefusalFallbackAgent") { on_refusal fallback: "openai/gpt-image-other" }
    server.reply(json: blocked, status: "400 Bad Request")
    server.reply(json: painted)
    result = run(drawing("SpecRefusalFallbackWorkflow"))

    expect(result.state).to eq(:done)
    expect(server.requests.map(&:path)).to eq(%w[/v1/images/edits /v1/images/edits])
    expect(server.requests.last.body[/name="model"\r\n\r\n([^\r]+)/, 1]).to eq("gpt-image-other")
  end

  it "prices an answer's output as image where its usage names no parts" do
    image_agent("SpecNoPartsAgent")
    server.reply(json: painted.merge("usage" => usage.except("output_tokens_details")))
    entry = run(drawing("SpecNoPartsWorkflow")).usage_entries.sole

    expect(entry.image_output_tokens).to eq(823)
    expect(entry.cost).to be_within(1e-12).of((77 * 0.000005) + (323 * 0.000008) + (823 * 0.00003))
  end

  it "keeps the usage of an answer with no image, an output failure never asked for again" do
    image_agent("SpecNoImageAgent")
    server.reply(json: painted.merge("data" => [{ "url" => nil }]))
    result = run(drawing("SpecNoImageWorkflow"))

    expect(failure(result)).to be_a(Smith::OutputInvalid)
    expect(result.usage_entries.sole.to_h).to include(output_tokens: 823, attempt_kind: :partial_attempt)
    expect(server.requests.size).to eq(1)
  end

  it "takes no tools, output schema or thinking" do
    tool = Class.new(Smith::Tool) do
      def self.name = "SpecLookup"
      description "looks"
      def execute = "x"
    end
    {
      "SpecToolsImageAgent" => -> { tools tool },
      "SpecSchemaImageAgent" => -> { output_schema Class.new(RubyLLM::Schema) { string :x } },
      "SpecThinkingImageAgent" => -> { thinking effort: :low }
    }.each do |name, body|
      image_agent(name) { instance_exec(&body) }
      result = run(drawing("#{name}Workflow"))

      expect(failure(result)).to be_a(Smith::WorkflowError)
      expect(failure(result).message).to include("answers with an image")
    end
    expect(server.requests).to be_empty
  end

  it "is refused in a streamed step and in a batch step, sending nothing" do
    sink = Class.new { %i[start delta reset finish fail withdraw suspend].each { define_method(_1) { |*| nil } } }
    allow(Smith.config).to receive(:stream_sinks).and_return(reply: ->(_info) { sink.new })
    Smith.config.batch_queue = queue = batch_queue
    image_agent("SpecStepModesImageAgent")
    streamed = run(drawing("SpecStreamedImageWorkflow", stream: :reply))
    batched = run(drawing("SpecBatchedImageWorkflow", mode: :batch))

    expect([failure(streamed), failure(batched)]).to all(be_a(Smith::WorkflowError))
    expect(failure(streamed).message).to end_with("answers with an image, which takes no a streamed step")
    expect(failure(batched).message).to end_with("answers with an image, which takes no a batch")
    expect([server.requests, queue.items, ledger.calls]).to eq([[], [], []])
  end

  # The attempt's id is drawn once the agent is taken, so a refused one draws
  # none (the order 0.16.0 drew in).
  it "draws no attempt id for an image agent it refuses" do
    tool = Class.new(Smith::Tool) do
      def self.name = "SpecRefusedLookup"
      description "looks"
      def execute = "x"
    end
    refused = image_agent("SpecRefusedImageAgent") { tools tool }
    workflow = drawing("SpecRefusedImageWorkflow").new(context: {})
    allow(SecureRandom).to receive(:uuid).and_call_original

    expect { Smith::ImageAttempt.new(workflow, refused).call(nil, nil, attempt_index: 0) }
      .to raise_error(Smith::WorkflowError, /takes no tools/)
    expect(SecureRandom).not_to have_received(:uuid)
  end

  # RubyLLM's providers but OpenAI take no image to paint from.
  it "takes a model that takes none of its content to the fallback, as any agent" do
    saved = RubyLLM.config.gemini_api_key
    RubyLLM.config.gemini_api_key = "test"
    image_agent("SpecUnsupportedAgent") do
      model "imagen-test", provider: :gemini, assume_model_exists: true
      fallback_models "openai/gpt-image-other"
    end
    server.reply(json: painted)
    result = run(drawing("SpecUnsupportedWorkflow"))

    expect(result.state).to eq(:done)
    expect(server.requests.map { _1.body[/name="model"\r\n\r\n([^\r]+)/, 1] }).to eq(%w[gpt-image-other])
  ensure
    RubyLLM.config.gemini_api_key = saved
  end

  # An image agent is one that declares `image`, Smith's own record of it,
  # never one with a method of that name for its own reasons.
  it "takes an agent with an image_request of its own as an ordinary agent, which chats" do
    {
      "SpecOwnRequestAgent" => -> { define_singleton_method(:image_request) { { size: "1024x1024", quality: "low" } } },
      "SpecOwnRequestArgumentAgent" => -> { define_singleton_method(:image_request) { |url| url } },
      "SpecOwnRequestMemoAgent" => lambda do
        @image_request = { size: "1024x1024", quality: "low" }
        define_singleton_method(:image_request) { @image_request ||= {} }
      end,
      "SpecOwnInstanceRequestAgent" => -> { define_method(:image_request) { { size: "1024x1024" } } }
    }.each do |name, body|
      agent(name, &body)
      server.reply(json: message("words, no image"))
      result = asking("#{name}Workflow").new(context: {}).run!

      expect([result.state, result.context[:answer]]).to eq([:done, "words, no image"]), name
    end
    expect(server.requests.map(&:path)).to eq(["/v1/messages"] * 4)
  end

  it "fails an agent with an image_request of its own over to its fallback on a server's error, as any agent" do
    agent("SpecOwnRequestFallbackAgent") do
      define_singleton_method(:image_request) { { size: "1024x1024", quality: "low" } }
      fallback_models "anthropic/claude-haiku-5-5"
    end
    server.reply(json: { "type" => "error", "error" => { "type" => "api_error", "message" => "Internal" } },
                 status: "500 Internal Server Error")
    server.reply(json: message("from the fallback"))
    result = asking("SpecOwnRequestFallbackWorkflow").new(context: {}).run!

    expect([result.state, result.context[:answer], server.requests.size]).to eq([:done, "from the fallback", 2])
  end

  it "paints for an agent that declares image, and its subclass, whatever their own image readers answer" do
    declared = image_agent("SpecDeclaredAgent") do
      image size: "1024x1024", quality: "low", output_format: "webp"
      define_singleton_method(:image_request) { nil }
      define_singleton_method(:image_media_type) { "text/plain" }
    end
    server.reply(json: painted)
    part = run(drawing("SpecDeclaredWorkflow")).context[:drawn]
    Smith::Agent::Registry.delete(:spec_image_agent)
    with_stubbed_class("SpecDeclaredChildAgent", declared) { register_as :spec_image_agent }
    server.reply(json: painted)
    inherited = run(drawing("SpecDeclaredChildWorkflow")).context[:drawn]
    plain = image_agent("SpecPlainDeclaredAgent")

    expect([part, inherited]).to all(include(type: "image", media_type: "image/webp"))
    expect(server.requests.map(&:path)).to eq(["/v1/images/edits"] * 2)
    expect(server.requests.map(&:body)).to all(include("name=\"output_format\"\r\n\r\nwebp"))
    expect([plain.image_request, plain.image_media_type])
      .to eq([{ size: "1024x1024", quality: "low", background: "opaque", output_format: "png" }, "image/png"])
  end

  # Smith's own record of the declaration: frozen, so no reader's caller
  # changes what is sent; read whatever `@image_request` an agent keeps; and
  # copied to a subclass made after it, never to one made before.
  it "keeps its declaration frozen, apart from the agent's own @image_request, and copies it to later subclasses" do
    declared = { size: "1024x1024", quality: "low", background: "opaque", output_format: "png" }
    own = image_agent("SpecOwnIvarImageAgent") { @image_request = { size: "mine" } }
    plain = agent("SpecOwnIvarPlainAgent") { @image_request = { size: "mine" } }
    parent = agent("SpecLateDeclaringAgent")
    early = Class.new(parent)
    parent.image size: "1024x1024", quality: "low"
    late = Class.new(parent)

    expect([own.image_request, plain.image_request]).to eq([declared, nil])
    expect(own.image_request).to be_frozen
    expect { own.image_request[:size] = "512x512" }.to raise_error(FrozenError)
    expect([early.image_request, late.image_request]).to eq([nil, declared.except(:background)])
  end

  it "is declared with the provider's words and one of its output formats" do
    expect { image_agent("SpecBadSizeAgent") { image size: 1024, quality: "low" } }
      .to raise_error(ArgumentError, /Strings/)
    expect { image_agent("SpecBadFormatAgent") { image size: "1024x1024", quality: "low", output_format: "bmp" } }
      .to raise_error(ArgumentError, /output_format/)
  end
end
