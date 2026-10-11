# frozen_string_literal: true

require "json"

RSpec.describe "Smith output integrity: tools, budgets, limits, repairs and checks" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:chats) { [] }
  let(:reply_class) { Struct.new(:content, :input_tokens, :output_tokens, :raw) }

  after { %i[spec_review_agent spec_review_other spec_review_third].each { Smith::Agent::Registry.delete(_1) } }

  def anthropic_body(stop_reason) = { "type" => "message", "id" => "msg_1", "stop_reason" => stop_reason }

  # A chat that records what it was given and answers each reply in turn
  # ([content, raw body, tokens]); a sixth call fails the example rather
  # than looping.
  def fake_chat(replies, before_reply: nil)
    recorded = chats
    lambda do |**options|
      raise "more calls than any output policy allows" if recorded.size >= 6

      chat = { messages: [], params: {}, schema: nil, options: }
      recorded << chat
      content, raw, tokens = replies.length > 1 ? replies.shift : replies.first
      double_chat(chat, reply_class.new(content, tokens || 1, tokens || 1, raw), before_reply)
    end
  end

  def double_chat(chat, reply, before_reply)
    object = Object.new
    object.define_singleton_method(:add_message) { |message| chat[:messages] << message }
    object.define_singleton_method(:with_schema) { |schema| chat[:schema] = schema and self }
    object.define_singleton_method(:params) { chat[:params] }
    object.define_singleton_method(:with_params) { |**params| chat[:params] = params and self }
    object.define_singleton_method(:complete) do
      before_reply&.call
      chat[:completed] = true
      reply
    end
    object
  end

  def agent(name, replies, register: :spec_review_agent, before_reply: nil, &body)
    klass = with_stubbed_class(name, agent_class) do
      register_as register
      model "claude-opus-5-5", provider: :anthropic
    end
    klass.class_exec(&body) if body
    allow(klass).to receive(:chat, &fake_chat(replies, before_reply:))
    klass
  end

  def flow(name, agent_name = :spec_review_agent, seed: nil, &extra)
    klass = with_stubbed_class(name, workflow_class) do
      seed_messages { |_context| [{ role: :user, content: seed }] } if seed
      initial_state :idle
      state :failed
      transition :ask, from: :idle, to: :done do
        execute agent_name
        on_failure :fail
      end
    end
    klass.class_exec(&extra) if extra
    klass
  end

  def failure(result) = result.steps.last[:error]

  let(:review_schema) do
    Class.new do
      def to_json_schema
        { name: "review", schema: { type: "object", required: %w[score],
                                    properties: { score: { type: "integer", maximum: 5 } } } }
      end
    end
  end

  describe "follow-up calls" do
    it "are never made once a tool has run in the step, so the tools do not run again" do
      schema = review_schema
      tool_ran = -> { Smith::Tool.current_tool_execution_tracker.mark_started! }
      agent("SpecToolsAgent", [[{ "score" => 9 }, anthropic_body("end_turn")]], before_reply: tool_ran) do
        output_schema schema
      end

      result = flow("SpecToolsWorkflow").new.run!

      expect(failure(result)).to be_a(Smith::ToolOutcomeUncertain)
      expect(failure(result).cause).to be_a(Smith::OutputInvalid)
      expect(chats.size).to eq(1)
    end

    it "raise the failure they were making up for when they fail, and retry_on Smith::AgentError makes no more" do
      calls = 0
      klass = agent("SpecFailingFollowUpAgent", []) { on_truncation retry_with: { max_tokens: 32_000 } }
      answers = fake_chat([["half", anthropic_body("max_tokens")]])
      allow(klass).to receive(:chat) do |**options|
        calls += 1
        raise RubyLLM::OverloadedError, "overloaded" if calls.even?

        answers.call(**options)
      end
      workflow = flow("SpecFailingFollowUpWorkflow") do
        find_transition(:ask).instance_exec { retry_on Smith::AgentError, attempts: 3 }
      end

      result = workflow.new.run!

      expect(failure(result)).to be_a(Smith::OutputTruncated)
      expect(failure(result).cause).to be_a(RubyLLM::OverloadedError)
      expect(calls).to eq(2)
    end

    it "stop once the call has spent what its step reserved" do
      schema = review_schema
      agent("SpecBudgetAgent", [[{ "score" => 9 }, anthropic_body("end_turn"), 60]]) { output_schema schema }
      workflow = flow("SpecBudgetWorkflow") { budget total_tokens: 100 }.new

      result = workflow.run!

      expect(failure(result)).to be_a(Smith::OutputInvalid)
      expect(chats.size).to eq(1)
      expect(workflow.ledger.consumed[:total_tokens]).to eq(120)
    end

    it "may take every recovery the agent declares: a fallback, a retry and three repairs" do
      schema = review_schema
      agent("SpecEveryRecoveryAgent", [["no", anthropic_body("refusal")], ["{", anthropic_body("max_tokens")],
                                       [{ "score" => 9 }, anthropic_body("end_turn")],
                                       [{ "score" => 8 }, anthropic_body("end_turn")],
                                       [{ "score" => 7 }, anthropic_body("end_turn")],
                                       [{ "score" => 1 }, anthropic_body("end_turn")]]) do
        output_schema schema
        output_repairs 3
        on_truncation retry_with: { max_tokens: 32_000 }
        on_refusal fallback: "anthropic/claude-sonnet-5-5"
      end

      expect(flow("SpecEveryRecoveryWorkflow").new.run!.output).to eq("score" => 1)
      expect(chats.size).to eq(6)
    end

    it "judge a later step by its own reservation, not an earlier step's" do
      schema = review_schema
      agent("SpecBudgetedAgent", [["fine", anthropic_body("end_turn"), 50]], register: :spec_review_other) do
        budget token_limit: 100
      end
      agent("SpecUnbudgetedAgent", [[{ "score" => 9 }, anthropic_body("end_turn"), 500],
                                    [{ "score" => 1 }, anthropic_body("end_turn")]]) { output_schema schema }
      klass = with_stubbed_class("SpecTwoBudgetsWorkflow", workflow_class) do
        initial_state :idle
        transition(:first, from: :idle, to: :half) { execute :spec_review_other }
        transition(:second, from: :half, to: :done) { execute :spec_review_agent }
      end

      expect(klass.new.run!.output).to eq("score" => 1)
    end

    it "check the deadline before each call" do
      schema = review_schema
      answered = false
      agent("SpecDeadlineAgent", [[{ "score" => 9 }, anthropic_body("end_turn")]],
            before_reply: -> { answered = true }) { output_schema schema }
      workflow = flow("SpecDeadlineWorkflow").new
      workflow.define_singleton_method(:check_deadline!) { raise Smith::DeadlineExceeded, "deadline" if answered }

      expect(failure(workflow.run!)).to be_a(Smith::DeadlineExceeded)
      expect(chats.size).to eq(1)
    end

    it "count up the attempt index and leave an :output_rejected trace for each rejected response" do
      schema = review_schema
      agent("SpecTracedAgent", [[{ "score" => 9 }, anthropic_body("end_turn")],
                                [{ "score" => 4 }, anthropic_body("end_turn")]]) { output_schema schema }
      adapter = Smith::Trace::Memory.new
      allow(Smith.config).to receive(:trace_adapter).and_return(adapter)

      flow("SpecTracedWorkflow").new.run!

      calls = adapter.traces.select { _1[:type] == :provider_call }.map { _1[:data][:attempt_index] }
      rejected = adapter.traces.select { _1[:type] == :output_rejected }.map { _1[:data] }
      expect(calls).to eq([0, 1])
      expect(rejected.map { _1.slice(:error_class, :problem_count, :follow_up) })
        .to eq([{ error_class: "Smith::OutputInvalid", problem_count: 1, follow_up: :repair }])
    end
  end

  describe "a cut-off response" do
    it "is not retried when it ran out of context, or with a limit no larger than the request had" do
      agent("SpecContextAgent", [["half", anthropic_body("model_context_window_exceeded")]]) do
        on_truncation retry_with: { max_tokens: 32_000 }
      end
      expect(failure(flow("SpecContextWorkflow").new.run!)).to be_a(Smith::OutputTruncated)
      expect(chats.size).to eq(1)

      chats.clear
      agent("SpecSmallerAgent", [["half", anthropic_body("max_tokens")]], register: :spec_review_other) do
        params max_tokens: 50_000
        on_truncation retry_with: { max_tokens: 32_000 }
      end
      expect(failure(flow("SpecSmallerWorkflow", :spec_review_other).new.run!)).to be_a(Smith::OutputTruncated)
      expect(chats.size).to eq(1)
    end

    it "keeps the larger limit for a repair after the retry" do
      schema = review_schema
      agent("SpecKeptLimitAgent", [["{", anthropic_body("max_tokens")], [{ "score" => 9 }, anthropic_body("end_turn")],
                                   [{ "score" => 2 }, anthropic_body("end_turn")]]) do
        output_schema schema
        on_truncation retry_with: { max_tokens: 32_000 }
      end

      expect(flow("SpecKeptLimitWorkflow").new.run!.output).to eq("score" => 2)
      expect(chats.map { _1[:params] }).to eq([{}, { max_tokens: 32_000 }, { max_tokens: 32_000 }])
    end

    it "takes an Anthropic model's own maximum as the limit the request had" do
      limit = Smith::Providers::OutputLimit
      known = Smith::Agent::ModelReference.new(model_id: "claude-sonnet-4-5", provider: :anthropic)
      unknown = Smith::Agent::ModelReference.new(model_id: "claude-no-such-model", provider: :anthropic)

      expect(limit.current("anthropic", {}, known)).to eq(64_000)
      expect(limit.current("anthropic", {}, unknown)).to eq(4096)
    end

    it "keeps an OpenAI chat's own max_tokens key" do
      limit = Smith::Providers::OutputLimit
      reference = Smith::Agent::ModelReference.new(model_id: "gpt-5-mini", provider: :openai)

      expect(limit.params("openai", { max_tokens: 10 }, 99)).to eq(max_tokens: 99)
      expect(limit.current("openai", { max_tokens: 10 }, reference)).to eq(10)
      expect(limit.current("openai", {}, reference)).to be_nil
      expect(limit.current("gemini", { "generationConfig" => { "maxOutputTokens" => 7 } }, reference)).to eq(7)
    end
  end

  describe "a refusal" do
    it "reads a Gemini prompt block as refused" do
      facts = Smith::Providers::ResponseFacts.from_message(
        reply_class.new(nil, 1, 1, { "promptFeedback" => { "blockReason" => "OTHER" }, "responseId" => "g1" })
      )

      expect(facts).to eq(stop_reason: "prompt_blocked", provider_message_id: "g1")
      expect(Smith::Providers::StopReason.classify("prompt_blocked")).to eq(:refused)
    end

    it "prefers a Responses refusal to its incomplete reason" do
      body = { "object" => "response", "id" => "r", "incomplete_details" => { "reason" => "max_output_tokens" },
               "output" => [{ "content" => [{ "type" => "refusal" }] }] }

      expect(Smith::Providers::ResponseFacts.from_message(reply_class.new(nil, 1, 1, body))[:stop_reason])
        .to eq("refusal")
    end
  end

  describe "a structured output" do
    it "is left to BlankAgentOutputError when blank, without a repair" do
      schema = review_schema
      agent("SpecBlankAgent", [["  ", anthropic_body("end_turn")]]) { output_schema schema }

      expect(failure(flow("SpecBlankWorkflow").new.run!)).to be_a(Smith::BlankAgentOutputError)
      expect(chats.size).to eq(1)
    end

    it "is repaired after a handoff with the step's continuation turn kept" do
      schema = review_schema
      agent("SpecHandoffWriter", [["draft text", anthropic_body("end_turn")]], register: :spec_review_other)
      agent("SpecHandoffChecker", [[{ "score" => 9 }, anthropic_body("end_turn")],
                                   [{ "score" => 1 }, anthropic_body("end_turn")]]) { output_schema schema }
      klass = with_stubbed_class("SpecHandoffWorkflow", workflow_class) do
        seed_messages { |_context| [{ role: :user, content: "go" }] }
        initial_state :idle
        transition(:write, from: :idle, to: :written) { execute :spec_review_other }
        transition(:check, from: :written, to: :done) { execute :spec_review_agent }
      end

      klass.new.run!

      roles = chats.last[:messages].map { [_1[:role], _1[:content].to_s[0, 10]] }
      expect(roles).to eq([[:user, "go"], [:assistant, "draft text"], [:user, "Use the pr"],
                           [:assistant, "{\"score\":9"], [:user, "Your previ"]])
    end

    it "is checked after after_completion, which a refused response never reaches" do
      schema = review_schema
      seen = []
      agent("SpecHookAgent", [["score is three", anthropic_body("end_turn")]]) do
        output_schema schema
        define_method(:after_completion) do |content, _context|
          seen << content
          { "score" => 3 }
        end
      end
      expect(flow("SpecHookWorkflow").new.run!.output).to eq("score" => 3)

      agent("SpecRefusedHookAgent", [["no", anthropic_body("refusal")]], register: :spec_review_other) do
        define_method(:after_completion) { |content, _context| seen << content and content }
      end
      flow("SpecRefusedHookWorkflow", :spec_review_other).new.run!
      expect(seen).to eq(["score is three"])
    end

    it "gets the checks and the Anthropic shaping when declared with RubyLLM's schema macro" do
      schema = review_schema
      agent("SpecMacroAgent", [[{ "score" => 9 }, anthropic_body("end_turn")],
                               [{ "score" => 2 }, anthropic_body("end_turn")]]) { schema schema }

      expect(flow("SpecMacroWorkflow").new.run!.output).to eq("score" => 2)
      expect(chats.first[:schema]["schema"]["properties"]["score"]).to eq("type" => "integer")
    end

    it "refuses a schema Anthropic cannot take before the call, without retrying, and readiness reports it" do
      open_schema = Class.new do
        def to_json_schema
          { name: "open",
            schema: { type: "object", properties: { a: { type: "string" } }, additionalProperties: true } }
        end
      end
      agent("SpecOpenAgent", [["x", anthropic_body("end_turn")]]) { output_schema open_schema }
      klass = flow("SpecOpenWorkflow")

      error = failure(klass.new.run!)

      expect(error).to be_a(Smith::WorkflowError)
      expect(Smith::Errors.retryable?(error)).to be(false)
      expect(chats.count { _1[:completed] }).to eq(0)
      expect(klass.graph.runtime_readiness.errors.map(&:code)).to include(:output_schema_unsupported)

      other = with_stubbed_class("SpecOpenOpenAIAgent", agent_class) do
        register_as :spec_review_other
        model "gpt-5-mini", provider: :openai
        output_schema open_schema
      end
      expect(other.output_schema).to eq(open_schema)
      expect(flow("SpecOpenOpenAIWorkflow", :spec_review_other).graph.runtime_readiness.diagnostics.map(&:code))
        .not_to include(:output_schema_unsupported)
    end
  end

  describe "an output contract" do
    def contract_agent(name, verdict, register, schema: true)
      checker = Class.new { define_method(:call) { |_output| verdict } }
      review = review_schema
      agent(name, [['{"score":1}', anthropic_body("end_turn")]], register:) do
        output_schema review if schema
        output_contract checker
        output_repairs 0
      end
    end

    it "fails on a verdict with no messages, on false, and on Array errors" do
      empty = Struct.new(:errors) { def success? = false }.new({})
      listed = Struct.new(:errors) { def success? = false }.new(["too short", "no title"])

      contract_agent("SpecEmptyContract", empty, :spec_review_agent)
      expect(failure(flow("SpecEmptyContractWorkflow").new.run!).problems).to eq(["/: fails the output contract"])
      contract_agent("SpecFalseContract", false, :spec_review_other)
      expect(failure(flow("SpecFalseContractWorkflow", :spec_review_other).new.run!).problems)
        .to eq(["/: fails the output contract"])
      contract_agent("SpecListedContract", listed, :spec_review_third)
      expect(failure(flow("SpecListedContractWorkflow", :spec_review_third).new.run!).problems)
        .to eq(["/: too short", "/: no title"])
    end

    it "accepts true, reads JSON text without a schema, and refuses a verdict it cannot read" do
      contract_agent("SpecTrueContract", true, :spec_review_agent, schema: false)
      expect(flow("SpecTrueContractWorkflow").new.run!.output).to eq("score" => 1)

      contract_agent("SpecOddContract", :maybe, :spec_review_other)
      expect(failure(flow("SpecOddContractWorkflow", :spec_review_other).new.run!).message)
        .to match(/output_contract must return/)
    end

    it "caps the problems a schema and a contract find together at 20, and they restore" do
      fields = (1..20).to_h { ["f#{_1}", { type: "integer", maximum: 0 }] }
      wide = Class.new do
        define_method(:to_json_schema) { { name: "wide", schema: { type: "object", properties: fields } } }
      end
      many = Struct.new(:errors) { def success? = false }.new((1..20).to_h { [:"c#{_1}", ["is wrong"]] })
      checker = Class.new { define_method(:call) { |_output| many } }
      agent("SpecWideAgent", [[(1..20).to_h { ["f#{_1}", 1] }, anthropic_body("end_turn")]]) do
        output_schema wide
        output_contract checker
        output_repairs 0
      end
      klass = flow("SpecWideWorkflow")
      ran = klass.new.tap(&:run!)

      restored = klass.from_state(JSON.parse(JSON.generate(ran.to_state))).run!.last_error

      expect(restored).to be_a(Smith::OutputInvalid)
      expect(restored.problems.size).to eq(20)
      expect(restored.problems.first).to eq("/f1: is above the maximum 0")
    end
  end

  describe "runtime readiness" do
    it "accepts an agent with fallback models alone in a role that needs a model" do
      with_stubbed_class("SpecFallbackRouter", agent_class) do
        register_as :spec_review_agent
        fallback_models "openai/gpt-5-mini"
      end
      klass = with_stubbed_class("SpecFallbackRouteWorkflow", workflow_class) do
        initial_state :idle
        transition :route, from: :idle, to: :routed do
          route :spec_review_agent, routes: { done: :finish }, confidence_threshold: 0.5, fallback: :finish
        end
        transition :finish, from: :routed, to: :done
      end

      codes = klass.graph.runtime_readiness.diagnostics.map(&:code)

      expect(codes).not_to include(:agent_without_required_model, :agent_without_model)
    end
  end

  describe "the persisted failures" do
    let(:details) { { "agent_name" => "a", "model_used" => "m", "stop_reason" => nil, "problems" => ["/x: bad"] } }

    def validate(record)
      Smith::Workflow::FailureRecordValidator.new({ transition: :t, from: :a, to: :b,
                                                    error_message: "m" }.merge(record))
                                             .call
    end

    it "keep their problems through a restore, and are refused with the wrong family or bad details" do
      error = Smith::OutputInvalid.from_details(details)
      expect(Smith::OutputInvalid.from_details(JSON.parse(JSON.generate(error.details))).problems).to eq(["/x: bad"])

      good = { error_class: "Smith::OutputInvalid", error_family: "output_failure", error_details: details }
      expect(validate(good)).to include(error_family: "output_failure")
      [good.merge(error_family: "agent_error"), good.merge(error_details: details.merge("extra" => 1)),
       good.merge(error_details: details.except("problems"))].each do |bad|
        expect { validate(bad) }.to raise_error(Smith::PersistedFailureInvalid)
      end
      expect { Smith::OutputInvalid.from_details(details.merge(agent_name: "b")) }
        .to raise_error(ArgumentError, /duplicate/)
    end

    it "restore a known class with the message they were persisted with" do
      restored = Smith::Workflow::FailureReconstructor.new(
        snapshot: { transition: :t, from: :a, to: :b, error_class: "Smith::OutputTruncated",
                    error_family: "output_failure", error_message: "persisted text",
                    error_details: details.merge("problems" => []) },
        transition_normalizer: ->(name) { name }, state_normalizer: ->(name) { name }
      ).call[:error]

      expect(restored).to be_an_instance_of(Smith::OutputTruncated)
      expect(restored.message).to eq("persisted text")
    end

    it "are their own family in a durable composite branch" do
      evidence = Smith::Workflow::Composite::ErrorEvidence.call(Smith::OutputRefused.new(agent_name: :a,
                                                                                         model_used: "m"))

      expect(evidence.to_h).to include(family: "output_failure", retryable: false)
    end
  end

  describe Smith::Providers::SchemaConstraints do
    it "strips tuple items and under not, closes nullable objects, and refuses a free-form one" do
      payload = { "schema" => {
        "type" => "object", "properties" => {
          "pair" => { "type" => "array", "items" => [{ "type" => "integer", "minimum" => 1 }] },
          "maybe" => { "type" => %w[object null], "properties" => { "a" => { "type" => "string" } } },
          "never" => { "not" => { "type" => "string", "maxLength" => 3 } }
        }
      } }

      sent = described_class.for_provider(payload, "anthropic")["schema"]["properties"]

      expect(sent["pair"]["items"]).to eq([{ "type" => "integer" }])
      expect(sent["maybe"]["additionalProperties"]).to be(false)
      expect(sent["never"]["not"]).to eq("type" => "string")
      [{ "type" => "object" }, { "type" => %w[object null] }].each do |free_form|
        expect { described_class.for_provider({ "schema" => free_form }, "anthropic") }
          .to raise_error(Smith::WorkflowError), free_form.inspect
      end
    end

    it "checks decimals, integral floats, duplicates, deep refs, oneOf, prefixItems and definitions" do
      schema = {
        "type" => "object",
        "properties" => {
          "price" => { "type" => "number", "multipleOf" => 0.01 },
          "count" => { "anyOf" => [{ "type" => "integer" }, { "type" => "null" }] },
          "tags" => { "type" => "array", "uniqueItems" => true },
          "deep" => { "$ref" => "#/$defs/box/properties/inner" },
          "pick" => { "oneOf" => [{ "type" => "string" }, { "type" => "string", "maxLength" => 9 }] },
          "pair" => { "type" => "array", "prefixItems" => [{ "type" => "integer", "exclusiveMinimum" => 0 }] },
          "old" => { "$ref" => "#/definitions/small" }
        },
        "$defs" => { "box" => { "properties" => { "inner" => { "type" => "integer", "maximum" => 1 } } } },
        "definitions" => { "small" => { "type" => "integer", "maximum" => 1 } }
      }
      good = { "price" => 5, "count" => 3.0, "tags" => [1, 2], "deep" => 1, "pick" => "long string", "pair" => [1],
               "old" => 1 }

      expect(described_class.problems(schema, good)).to be_empty
      expect(described_class.problems({ "type" => "number", "multipleOf" => 0.1 }, 1_000_000_000)).to be_empty
      expect(described_class.problems(schema, good.merge("price" => 5.001, "tags" => [1, 1.0], "deep" => 2,
                                                         "pick" => "short", "pair" => [0], "old" => 2)))
        .to eq(["/price: is not a multiple of 0.01", "/tags: has duplicate items", "/deep: is above the maximum 1",
                "/pick: matches more than one of the allowed forms", "/pair/0: must be above 0",
                "/old: is above the maximum 1"])
    end

    it "checks properties beside an anyOf, and nested alternatives in time that grows slowly with depth" do
      beside = { "anyOf" => [{ "type" => "object" }], "required" => ["id"], "properties" => {} }
      expect(described_class.problems(beside, {})).to eq(["/: is missing id"])
      tree = { "type" => "object",
               "properties" => { "n" => { "type" => "integer", "maximum" => 1 }, "next" => { "$ref" => "#" } } }
      expect(described_class.problems(tree, { "next" => { "next" => { "n" => 2 } } }))
        .to eq(["/next/next/n: is above the maximum 1"])

      node = { "anyOf" => [{ "type" => "object", "properties" => { "next" => { "$ref" => "#" } } },
                           { "type" => "object", "properties" => { "next" => { "$ref" => "#" } },
                             "required" => ["x"] }] }
      value = (1..30).reduce({}) { |inner, _| { "next" => inner } }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      described_class.problems(node, value)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.0
    end
  end
end
