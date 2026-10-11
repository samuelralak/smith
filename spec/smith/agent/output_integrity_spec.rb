# frozen_string_literal: true

require "json"

RSpec.describe "Smith output integrity: stop reasons, typed output errors, contracts and schema constraints" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:chats) { [] }

  after { %i[spec_output_agent spec_output_other].each { Smith::Agent::Registry.delete(_1) } }

  let(:reply_class) { Struct.new(:content, :input_tokens, :output_tokens, :raw) }

  def anthropic_body(stop_reason) = { "type" => "message", "id" => "msg_1", "stop_reason" => stop_reason }

  # A chat that records what it was given and answers each reply in turn;
  # a reply is [content, raw body].
  def fake_chat(replies)
    recorded = chats
    lock = Mutex.new
    lambda do |**_options|
      chat = { messages: [], params: {}, schema: nil }
      recorded << chat
      content, raw = lock.synchronize { replies.length > 1 ? replies.shift : replies.first }
      double_chat(chat, reply_class.new(content, 1, 1, raw))
    end
  end

  def double_chat(chat, reply)
    object = Object.new
    object.define_singleton_method(:add_message) { |message| chat[:messages] << message }
    object.define_singleton_method(:with_schema) { |schema| chat[:schema] = schema and self }
    object.define_singleton_method(:params) { chat[:params] }
    object.define_singleton_method(:with_params) { |**params| chat[:params] = params and self }
    object.define_singleton_method(:complete) { reply }
    object
  end

  def agent(name, replies, register: :spec_output_agent, provider: :anthropic, model: "claude-opus-5-5", &body)
    klass = with_stubbed_class(name, agent_class) do
      register_as register
      model model, provider:
    end
    klass.class_exec(&body) if body
    allow(klass).to receive(:chat, &fake_chat(replies))
    klass
  end

  def workflow(name, agent_name = :spec_output_agent, seed: nil)
    with_stubbed_class(name, workflow_class) do
      seed_messages { |_context| [{ role: :user, content: seed }] } if seed
      initial_state :idle
      state :failed
      transition :ask, from: :idle, to: :done do
        execute agent_name
        on_failure :fail
      end
    end
  end

  def run(name, agent_name = :spec_output_agent, seed: nil) = workflow(name, agent_name, seed:).new(context: {}).run!

  def failure(result) = result.steps.last[:error]

  describe Smith::Providers::StopReason do
    it "reads each provider's cut-off and refusal stop reasons, and nothing else" do
      %w[max_tokens model_context_window_exceeded length max_output_tokens MAX_TOKENS].each do |reason|
        expect(described_class.classify(reason)).to eq(:truncated), reason
      end
      %w[refusal content_filter SAFETY RECITATION BLOCKLIST PROHIBITED_CONTENT SPII IMAGE_SAFETY content_filtered
         guardrail_intervened].each { |reason| expect(described_class.classify(reason)).to eq(:refused), reason }
      [nil, "end_turn", "stop", "STOP", "tool_use", "completed", "Max_Tokens"].each do |reason|
        expect(described_class.classify(reason)).to be_nil, reason.inspect
      end
    end

    it "reports OpenAI's message-level refusals as the stop reason refusal" do
      facts = ->(raw) { Smith::Providers::ResponseFacts.from_message(reply_class.new(nil, 1, 1, raw)) }
      chat = { "object" => "chat.completion", "id" => "c1",
               "choices" => [{ "finish_reason" => "stop", "message" => { "refusal" => "I can't help" } }] }
      responses = { "object" => "response", "id" => "r1", "status" => "completed",
                    "output" => [{ "type" => "message", "content" => [{ "type" => "refusal", "refusal" => "No" }] }] }

      expect(facts.call(chat)).to eq(stop_reason: "refusal", provider_message_id: "c1")
      expect(facts.call(responses)).to eq(stop_reason: "refusal", provider_message_id: "r1")
      chat["choices"][0]["message"]["refusal"] = nil
      expect(facts.call(chat)[:stop_reason]).to eq("stop")
    end
  end

  describe "a cut-off response" do
    it "raises OutputTruncated by default, billing the response" do
      agent("SpecTruncatedAgent", [["half an ans", anthropic_body("max_tokens")]])

      result = run("SpecTruncatedWorkflow")

      expect(failure(result)).to be_a(Smith::OutputTruncated)
      expect(failure(result).message).to include(":spec_output_agent", "claude-opus-5-5", "stop reason max_tokens")
      expect(result.total_tokens).to eq(2)
    end

    it "keeps the cut-off output under on_truncation :accept" do
      agent("SpecAcceptedAgent", [["half an ans", anthropic_body("max_tokens")]]) { on_truncation :accept }

      expect(run("SpecAcceptedWorkflow").output).to eq("half an ans")
    end

    it "retries once with the provider's output limit, then raises when it is cut off again" do
      agent("SpecRetriedAgent",
            [["half", anthropic_body("max_tokens")], ["whole answer", anthropic_body("end_turn")]]) do
        on_truncation retry_with: { max_tokens: 32_000 }
      end
      result = run("SpecRetriedWorkflow")

      expect(result.output).to eq("whole answer")
      expect(chats.map { _1[:params] }).to eq([{}, { max_tokens: 32_000 }])
      expect(result.total_tokens).to eq(4)

      chats.clear
      agent("SpecRetriedTwiceAgent", [["half", anthropic_body("max_tokens")]], register: :spec_output_other) do
        on_truncation retry_with: { max_tokens: 32_000 }
      end
      expect(failure(run("SpecRetriedTwiceWorkflow", :spec_output_other))).to be_a(Smith::OutputTruncated)
      expect(chats.size).to eq(2)
    end

    it "settles the set-aside response into the budget with the accepted one, keeping the chat's own params" do
      settled = agent("SpecSettledAgent", []) { on_truncation retry_with: { max_tokens: 64 } }
      answers = fake_chat([["half", anthropic_body("max_tokens")], ["whole", anthropic_body("end_turn")]])
      allow(settled).to receive(:chat) { |**options| answers.call(**options).with_params(temperature: 0) }
      klass = with_stubbed_class("SpecSettledWorkflow", workflow_class) do
        initial_state :idle
        budget total_tokens: 1_000
        transition(:ask, from: :idle, to: :done) { execute :spec_output_agent }
      end
      workflow = klass.new

      workflow.run!

      expect(workflow.ledger.consumed[:total_tokens]).to eq(4)
      expect(chats.last[:params]).to eq(temperature: 0, max_tokens: 64)
    end

    it "settles a set-aside response once when the next call fails" do
      failing = agent("SpecFailedRetryAgent", []) { on_truncation retry_with: { max_tokens: 64 } }
      answers = fake_chat([["half", anthropic_body("max_tokens")]])
      calls = 0
      allow(failing).to receive(:chat) do |**options|
        calls += 1
        raise RubyLLM::ServerError, "provider down" if calls == 2

        answers.call(**options)
      end
      klass = with_stubbed_class("SpecFailedRetryWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        budget total_tokens: 1_000
        transition :ask, from: :idle, to: :done do
          execute :spec_output_agent
          on_failure :fail
        end
      end
      workflow = klass.new

      result = workflow.run!

      expect(failure(result)).to be_a(Smith::AgentError)
      expect(workflow.ledger.consumed[:total_tokens]).to eq(2)
    end

    it "maps the output limit to each provider's own parameter, and does not retry another provider" do
      limit = Smith::Providers::OutputLimit
      expect(limit.params("anthropic", {}, 9)).to eq(max_tokens: 9)
      expect(limit.params("openai", {}, 9)).to eq(max_completion_tokens: 9)
      expect(limit.params("openai", { openai_api_mode: :responses }, 9)).to eq(max_output_tokens: 9)
      expect(limit.params(:gemini, {}, 9)).to eq(generationConfig: { maxOutputTokens: 9 })
      expect(limit.params("vertexai", {}, 9)).to eq(generationConfig: { maxOutputTokens: 9 })
      expect(limit.params("bedrock", {}, 9)).to eq(inferenceConfig: { maxTokens: 9 })
      expect(limit.supported?("mistral")).to be(false)

      agent("SpecOtherProviderAgent", [["half", { "stopReason" => "max_tokens" }]], provider: :mistral,
                                                                                    model: "mistral-large") do
        on_truncation retry_with: { max_tokens: 9 }
      end
      expect(failure(run("SpecOtherProviderWorkflow"))).to be_a(Smith::OutputTruncated)
      expect(chats.size).to eq(1)
    end
  end

  describe "a refused response" do
    it "raises OutputRefused by default" do
      agent("SpecRefusedAgent", [["I can't help with that", anthropic_body("refusal")]])

      result = run("SpecRefusedWorkflow")

      expect(failure(result)).to be_a(Smith::OutputRefused)
      expect(failure(result).stop_reason).to eq("refusal")
    end

    it "tries the refusal fallback once, on that model" do
      agent("SpecFallbackAgent", [["no", anthropic_body("refusal")], ["yes", anthropic_body("end_turn")]]) do
        on_refusal fallback: "openai/gpt-5-mini"
      end
      result = run("SpecFallbackWorkflow")

      expect(result.output).to eq("yes")
      expect(result.steps.last).to include(model: "gpt-5-mini", provider: :openai)

      chats.clear
      agent("SpecFallbackRefusedAgent", [["no", anthropic_body("refusal")]], register: :spec_output_other) do
        on_refusal fallback: "openai/gpt-5-mini"
      end
      expect(failure(run("SpecFallbackRefusedWorkflow", :spec_output_other))).to be_a(Smith::OutputRefused)
      expect(chats.size).to eq(2)
    end

    it "falls back only once, even when the fallback reports a dated model id" do
      refusing = agent("SpecDatedFallbackAgent", []) { on_refusal fallback: "openai/gpt-5-mini" }
      answers = fake_chat([["no", anthropic_body("refusal")]])
      allow(refusing).to receive(:chat) do |**options|
        chat = answers.call(**options)
        dated = Struct.new(:id, :provider).new("#{options[:model]}-2026-06-01", options[:provider].to_s)
        chat.define_singleton_method(:model) { dated }
        chat
      end

      expect(failure(run("SpecDatedFallbackWorkflow"))).to be_a(Smith::OutputRefused)
      expect(chats.size).to eq(2)
    end

    it "does not fall back to the model that refused" do
      agent("SpecSameFallbackAgent", [["no", anthropic_body("refusal")]]) do
        on_refusal fallback: "anthropic/claude-opus-5-5"
      end

      expect(failure(run("SpecSameFallbackWorkflow"))).to be_a(Smith::OutputRefused)
      expect(chats.size).to eq(1)
    end
  end

  describe "a structured output" do
    let(:schema) do
      Class.new do
        def to_json_schema
          { name: "review", schema: {
            type: "object", required: %w[title score],
            properties: { title: { type: "string", maxLength: 10 }, score: { type: "integer", minimum: 0, maximum: 5 } }
          } }
        end
      end
    end

    it "sends Anthropic the schema without the constraints it rejects, and checks them on the output" do
      review = schema
      agent("SpecSchemaAgent", [[{ "title" => "a much too long title", "score" => 9 }, anthropic_body("end_turn")],
                                [{ "title" => "fine", "score" => 3 }, anthropic_body("end_turn")]]) do
        output_schema review
      end

      result = run("SpecSchemaWorkflow", seed: "review it")

      expect(result.output).to eq("title" => "fine", "score" => 3)
      sent = chats.first[:schema]["schema"]
      expect(sent["properties"]).to eq("title" => { "type" => "string" }, "score" => { "type" => "integer" })
      expect(sent["additionalProperties"]).to be(false)
      repair = chats.last[:messages]
      expect(repair.size).to eq(3)
      expect(repair[1]).to eq(role: :assistant, content: JSON.generate("title" => "a much too long title",
                                                                       "score" => 9))
      expect(repair[2][:content]).to include("- /title: has more than 10 characters",
                                             "- /score: is above the maximum 5")
    end

    it "raises OutputInvalid once the repairs are used up, and reads JSON text as the object it holds" do
      review = schema
      agent("SpecInvalidAgent", [["not json at all", anthropic_body("end_turn")]]) do
        output_schema review
        output_repairs 2
      end
      result = run("SpecInvalidWorkflow")

      expect(failure(result)).to be_a(Smith::OutputInvalid)
      expect(failure(result).problems).to eq(["/: is not a JSON object"])
      expect(chats.size).to eq(3)
      expect(result.total_tokens).to eq(6)

      chats.clear
      agent("SpecJsonTextAgent", [['{"title":"ok","score":1}', anthropic_body("end_turn")]],
            register: :spec_output_other) { output_schema review }
      expect(run("SpecJsonTextWorkflow", :spec_output_other).output).to eq("title" => "ok", "score" => 1)
    end

    it "checks the agent's output contract, with no repair when repairs are off" do
      contract = Class.new do
        def call(output)
          errors = output["title"] == "ok" ? {} : { title: ["must be ok"], meta: { tags: ["is missing"] } }
          Struct.new(:errors) { def success? = errors.empty? }.new(errors)
        end
      end
      agent("SpecContractAgent", [[{ "title" => "nope" }, anthropic_body("end_turn")]]) do
        output_contract contract
        output_repairs 0
      end

      result = run("SpecContractWorkflow")

      expect(failure(result)).to be_a(Smith::OutputInvalid)
      expect(failure(result).problems).to eq(["/title: must be ok", "/meta/tags: is missing"])
      expect(chats.size).to eq(1)
    end

    it "starts the repair from the rejected reply alone when the step had no messages" do
      review = schema
      agent("SpecNoInputAgent", [["prose", anthropic_body("end_turn")], [{ "title" => "a", "score" => 1 },
                                                                         anthropic_body("end_turn")]]) do
        output_schema review
      end

      run("SpecNoInputWorkflow")

      expect(chats.last[:messages].map { _1[:role] }).to eq([:user])
      expect(chats.last[:messages].sole[:content]).to start_with("Your previous reply was:\nprose")
    end
  end

  describe Smith::Providers::SchemaConstraints do
    let(:payload) do
      { "schema" => {
        "type" => "object",
        "properties" => {
          "n" => { "type" => "number", "exclusiveMinimum" => 0, "exclusiveMaximum" => 10, "multipleOf" => 0.5 },
          "tags" => { "type" => "array", "minItems" => 2, "maxItems" => 3, "uniqueItems" => true,
                      "items" => { "type" => "string", "minLength" => 2 } },
          "one" => { "type" => "array", "minItems" => 1, "items" => { "$ref" => "#/$defs/word" } },
          "either" => { "anyOf" => [{ "type" => "integer", "minimum" => 5 }, { "type" => "string" }] }
        },
        "$defs" => { "word" => { "type" => "object",
                                 "properties" => { "w" => { "type" => "string", "maxLength" => 3 } } } }
      } }
    end

    it "strips the rejected constraints for Anthropic only, closing every object" do
      sent = described_class.for_provider(payload, :anthropic)["schema"]

      expect(sent.dig("properties", "n")).to eq("type" => "number")
      expect(sent.dig("properties", "tags")).to eq("type" => "array", "items" => { "type" => "string" })
      expect(sent.dig("properties", "one", "minItems")).to eq(1)
      expect(sent.dig("properties", "either", "anyOf")).to eq([{ "type" => "integer" }, { "type" => "string" }])
      expect(sent.dig("$defs", "word")).to include("additionalProperties" => false)
      expect(sent["additionalProperties"]).to be(false)
      expect(described_class.for_provider(payload, :openai)).to equal(payload)
      open_object = { "schema" => { "type" => "object", "additionalProperties" => true } }
      expect { described_class.for_provider(open_object, "anthropic") }
        .to raise_error(Smith::AgentError, /additionalProperties/)
    end

    it "reports each broken constraint with its path, through refs and alternatives" do
      value = { "n" => 10.25, "tags" => %w[a a b c], "one" => [{ "w" => "long" }], "either" => 3 }

      expect(described_class.problems(payload["schema"], value)).to eq(
        [
          "/n: must be below 10", "/n: is not a multiple of 0.5", "/tags: has more than 3 items",
          "/tags: has duplicate items", "/tags/0: has fewer than 2 characters", "/tags/1: has fewer than 2 characters",
          "/tags/2: has fewer than 2 characters", "/tags/3: has fewer than 2 characters",
          "/one/0/w: has more than 3 characters", "/either: matches none of the allowed forms"
        ]
      )
      expect(described_class.problems(payload["schema"], { "n" => 2.5, "tags" => %w[ab cd], "either" => "x" }))
        .to be_empty
    end

    it "checks bounds at their edges and reports a missing required property" do
      schema = { "type" => "object", "required" => %w[low high],
                 "properties" => { "low" => { "type" => "integer", "minimum" => 0 },
                                   "high" => { "type" => "integer", "exclusiveMaximum" => 10 } } }

      expect(described_class.problems(schema, { "low" => 0, "high" => 9 })).to be_empty
      expect(described_class.problems(schema, { "low" => -1, "high" => 10 }))
        .to eq(["/low: is below the minimum 0", "/high: must be below 10"])
      expect(described_class.problems(schema, { "low" => 0 })).to eq(["/: is missing high"])
    end

    it "reports at most 20 problems, even when a value breaks two constraints at the limit" do
      schema = { "type" => "array", "items" => { "type" => "integer", "maximum" => 0, "multipleOf" => 2 } }

      expect(described_class.problems(schema, Array.new(50, 1)).size).to eq(20)
      expect(described_class.problems(schema, [2] + Array.new(50, 1)).size).to eq(20)
    end
  end

  describe "the output errors" do
    it "persist with a failed step and restore as the same error" do
      agent("SpecRestoredAgent", [["half", anthropic_body("max_tokens")]])
      klass = workflow("SpecRestoredWorkflow")
      ran = klass.new(context: {})
      ran.run!

      restored = klass.from_state(JSON.parse(JSON.generate(ran.to_state))).run!

      expect(restored.last_error).to be_a(Smith::OutputTruncated)
      expect(restored.last_error.details).to eq(agent_name: "spec_output_agent", model_used: "claude-opus-5-5",
                                                stop_reason: "max_tokens", problems: [])
    end

    it "are their own failure family, never retried, and not caught by retry_on Smith::AgentError" do
      error = Smith::OutputRefused.new(agent_name: :a, model_used: "m", stop_reason: "refusal")
      record = Smith::Workflow::FailureRecord.capture(transition: :t, from: :a, to: :b, error:)

      expect(record).to include(error_class: "Smith::OutputRefused", error_family: "output_failure")
      expect(Smith::Errors.retryable?(error)).to be(false)
      expect(error).not_to be_a(Smith::AgentError)

      agent("SpecNotRetriedAgent", [["no", anthropic_body("refusal")]])
      klass = with_stubbed_class("SpecNotRetriedWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :ask, from: :idle, to: :done do
          execute :spec_output_agent
          retry_on Smith::AgentError, attempts: 3
          on_failure :fail
        end
      end
      expect(failure(klass.new.run!)).to be_a(Smith::OutputRefused)
      expect(chats.size).to eq(1)
    end

    it "restore a record of an unknown output failure class as an OutputFailure" do
      details = { "agent_name" => "a", "model_used" => "m", "stop_reason" => nil, "problems" => [] }

      error = Smith::Workflow::FailureReconstructor.new(
        snapshot: { transition: :t, from: :a, to: :b, error_class: "Host::OutputGone", error_family: "output_failure",
                    error_message: "gone", error_details: details },
        transition_normalizer: ->(name) { name }, state_normalizer: ->(name) { name }
      ).call[:error]

      expect(error).to be_an_instance_of(Smith::OutputFailure)
      expect(error.message).to eq("agent :a response from model m could not be used")
    end

    it "refuses details that are not bounded" do
      good = { "agent_name" => "a", "model_used" => "m", "stop_reason" => nil, "problems" => ["x"] }

      expect(Smith::OutputInvalid.from_details(good).problems).to eq(["x"])
      [good.merge("extra" => 1), good.except("problems"), good.merge("problems" => Array.new(21, "x")),
       good.merge("model_used" => "m" * 300), good.merge("problems" => [1])].each do |bad|
        expect { Smith::OutputInvalid.from_details(bad) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "the agent macros" do
    it "validate their settings and pass to subclasses" do
      base = Class.new(agent_class) do
        on_truncation retry_with: { max_tokens: 100 }
        on_refusal fallback: "openai/gpt-5-mini"
        output_repairs 3
      end
      child = Class.new(base)

      expect(child.on_truncation).to eq(policy: :retry, max_tokens: 100)
      expect(child.on_refusal[:model].key).to eq([:openai, "gpt-5-mini"])
      expect(child.output_repairs).to eq(3)
      expect(Class.new(agent_class).on_truncation).to eq(policy: :fail)
      expect(Class.new(agent_class).output_repairs).to eq(1)
      [-> { on_truncation :maybe }, -> { on_truncation :fail, retry_with: { max_tokens: 1 } },
       -> { on_truncation retry_with: { max_tokens: 0 } }, -> { on_truncation retry_with: { tokens: 5 } },
       -> { on_refusal :retry }, -> { on_refusal fallback: "gpt-5-mini" }, -> { output_repairs 4 },
       -> { output_contract Object.new }].each do |setting|
        expect { Class.new(agent_class).class_exec(&setting) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "an agent without a model" do
    it "fails its step, on a serial and a fan-out step" do
      with_stubbed_class("SpecModellessAgent", agent_class) { register_as :spec_output_agent }
      fan = with_stubbed_class("SpecModellessFanWorkflow", workflow_class) do
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          fan_out branches: { a: :spec_output_agent }
          on_failure :fail
        end
      end

      expect(failure(run("SpecModellessWorkflow")).message).to match(/no executable model candidate/)
      expect(failure(fan.new.run!)).to be_a(Smith::AgentError)
    end
  end
end
