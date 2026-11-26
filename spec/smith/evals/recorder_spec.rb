# frozen_string_literal: true

require "json"
require "smith/evals"
require "smith/testing"

# The recorder (slice-1a design, 5.4): one step record per provider attempt
# of a trial, on every path a step runs, with its messages whatever Smith's
# trace content says, bounded as it arrives, priced from its own tokens.
RSpec.describe Smith::Evals::Recorder do
  include_context "with an eval trial"

  let(:testing) { Smith::Testing }
  let(:traces) { Smith::Trace::Memory.new }
  let(:label_schema) do
    Class.new do
      def to_json_schema
        { name: "label", schema: { type: "object", required: ["label"], properties: { label: { type: "string" } } } }
      end
    end
  end

  around do |example|
    unstubbed = testing.unstubbed
    example.run
  ensure
    testing.unstubbed = unstubbed
    testing.reset!
  end

  before do
    allow(Smith.config).to receive_messages(trace_adapter: traces, trace_content: false)
  end

  def provider_calls = traces.traces.select { _1[:type] == :provider_call }.map { _1[:data] }

  def workflow(name, &)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "Research the clinic." }] }
      class_exec(&)
    end
  end

  def stubbed(name, register, reply = "Noted.", **options, &)
    agent(name, register:, **options, &)
    testing.stub_agent(register, outputs: reply.respond_to?(:call) ? reply : ->(_request) { reply })
  end

  # An observation as the seam hands one over, for the bounds and prices:
  # one response with its tokens, unless it gives its own.
  def observed(number, **fields)
    tokens = fields.fetch(:tokens) do
      { input: 100, output: 20, cache_read: nil, cache_write: nil, thinking: nil, image_input: nil, image_output: nil }
    end
    Smith::AttemptObservation::Attempt.new(
      trial: trial_spec.trial_id, agent: "spec_agent", components: nil, attempt_id: "attempt-#{number}",
      attempt_index: 0, outcome: :completed, failure: nil, model: "claude-sonnet-5-5", provider: :anthropic,
      mode: :sync, memo: false, duration_ms: 10, tokens:,
      responses: tokens ? [{ tokens:, mode: fields.fetch(:mode, :sync) }] : [],
      stop_reason: "end_turn", messages: [{ "role" => "user", "text" => "Step #{number}." }], sent_count: 1,
      tool_call_names: [], position: { execution_key: nil, workflow: "W", transition: :ask, branch_key: nil,
                                       round: nil },
      started: nil, settings: { temperature: nil, max_output_tokens: nil, thinking: nil }, **fields.except(:tokens)
    )
  end

  describe "what a step record holds" do
    it "keeps each step's system, user and assistant messages and its reply, while traces keep no content" do
      shape = label_schema
      agent("SpecRecLabelAgent") do
        instructions { |_context| "Label the ticket." }
        output_schema shape
      end
      server.reply(json: message('{"label":"bug"}', tokens: [30, 5]))

      recorder = recorded { asking("SpecRecLabelWorkflow").new(context: {}).run! }
      step = recorder.steps.sole
      expect(step["messages"]).to eq([{ "role" => "system", "text" => "Label the ticket." },
                                      { "role" => "user", "text" => "classify this posting" },
                                      { "role" => "assistant", "json" => { "label" => "bug" } }])
      expect(step.slice("seq", "agent", "outcome", "model", "provider", "mode", "memo", "sent_count", "stop_reason"))
        .to eq("seq" => 1, "agent" => "spec_ledger_agent", "outcome" => "completed", "model" => "claude-sonnet-5-5",
               "provider" => "anthropic", "mode" => "sync", "memo" => false, "sent_count" => 2,
               "stop_reason" => "end_turn")
      expect(step["attempt_id"]).to eq(provider_calls.sole[:attempt_id])
      expect(step["tokens"]).to eq("input" => 30, "output" => 5, "cache_read" => 0, "cache_write" => 0, "thinking" => 0)
      expect(step["position"]).to eq("workflow" => "SpecRecLabelWorkflow", "transition" => "ask", "branch_key" => nil,
                                     "round" => nil, "execution_key" => nil)
      expect(traces.traces).not_to be_empty
      expect(traces.traces.flat_map { _1[:data].keys } & %i[content prompt response args result]).to eq([])
      expect(JSON.generate(traces.traces)).not_to include("Label the ticket.", "classify this posting", '"bug"')
      expect(step).to be_frozen
      expect_valid_steps(recorder.steps)
    end

    it "records one step per provider attempt across parallel branches, a fan-out, a nested run and optimize" do
      testing.unstubbed = :refuse
      stubbed("SpecRecFindAgent", :spec_rec_find, ->(request) { "Fact #{request.number}." })
      stubbed("SpecRecLeftAgent", :spec_rec_left)
      stubbed("SpecRecRightAgent", :spec_rec_right)
      stubbed("SpecRecChildAgent", :spec_rec_child, "The child read it.")
      stubbed("SpecRecDraftAgent", :spec_rec_draft, ->(request) { "Draft #{request.number}." })
      verdict = Class.new do
        def self.required_keys = %i[accept feedback]

        def to_json_schema
          { name: "verdict", schema: { type: "object", required: %w[accept feedback],
                                       properties: { accept: { type: "boolean" }, feedback: { type: "string" } } } }
        end
      end
      stubbed("SpecRecJudgeAgent", :spec_rec_judge, lambda { |request|
        { accept: request.number > 1, feedback: "Shorter." }
      })
      child = workflow("SpecRecChildWorkflow") do
        transition(:look, from: :idle, to: :done) { execute :spec_rec_child }
      end
      klass = workflow("SpecRecPathsWorkflow") do
        transition :find, from: :idle, to: :found do
          execute :spec_rec_find, parallel: true, count: 3
          on_failure :fail
        end
        transition :read, from: :found, to: :read do
          fan_out branches: { left: :spec_rec_left, right: :spec_rec_right }
          on_failure :fail
        end
        transition :nest, from: :read, to: :nested do
          workflow child
          on_failure :fail
        end
        transition :draft, from: :nested, to: :done do
          optimize generator: :spec_rec_draft, evaluator: :spec_rec_judge, max_rounds: 3, evaluator_schema: verdict
          on_failure :fail
        end
      end

      recorder = recorded { expect(klass.new(context: {}).run!.state).to eq(:done) }
      steps = recorder.steps
      expect(steps.map { _1["attempt_id"] }).to match_array(provider_calls.map { _1[:attempt_id] })
      expect(steps.map { _1["seq"] }).to eq((1..10).to_a)
      by = ->(transition) { steps.select { _1["position"]["transition"] == transition } }
      expect(by.call("find").length).to eq(3)
      expect(by.call("read").map { _1["position"]["branch_key"] }).to contain_exactly("left", "right")
      expect(steps.map { _1["position"]["workflow"] }).to include("SpecRecChildWorkflow")
      expect(by.call("draft").map { [_1["agent"], _1["position"]["round"]] })
        .to eq([["spec_rec_draft", 0], ["spec_rec_judge", 0], ["spec_rec_draft", 1], ["spec_rec_judge", 1]])
      expect_valid_steps(steps)
    end

    it "records each worker of an orchestrator, between the planner's two answers" do
      testing.unstubbed = :refuse
      tasks = Class.new do
        def self.required_keys = %i[task_id input]

        def to_json_schema
          { name: "task", schema: { type: "object", required: %w[task_id input],
                                    properties: { task_id: { type: "string" },
                                                  input: { type: "string" } } } }
        end
      end
      finding = Class.new do
        def self.required_keys = %i[finding]

        def to_json_schema
          { name: "finding", schema: { type: "object", required: %w[finding],
                                       properties: { finding: { type: "string" } } } }
        end
      end
      summary = Class.new do
        def self.required_keys = %i[summary]

        def to_json_schema
          { name: "summary", schema: { type: "object", required: %w[summary],
                                       properties: { summary: { type: "string" } } } }
        end
      end
      plan = Class.new do
        def to_json_schema
          task = { type: "object", required: %w[task_id input],
                   properties: { task_id: { type: "string" }, input: { type: "string" } } }
          { name: "plan", schema: { type: "object", required: [],
                                    properties: { tasks: { type: "array", items: task },
                                                  final: { type: "object", required: ["summary"],
                                                           properties: { summary: { type: "string" } } } } } }
        end
      end
      stubbed("SpecRecPlannerAgent", :spec_rec_planner, lambda { |request|
        next { tasks: [{ task_id: "t1", input: "hours" }, { task_id: "t2", input: "address" }] } if request.number == 1

        { final: { summary: "Opens at 8 on Main Street." } }
      }) do
        output_schema plan
        define_method(:after_completion) { |result, _context| JSON.parse(JSON.generate(result), symbolize_names: true) }
      end
      stubbed("SpecRecWorkerAgent", :spec_rec_worker, ->(request) { { finding: "Found #{request.number}." } })
      klass = workflow("SpecRecOrchestrateWorkflow") do
        transition :research, from: :idle, to: :done do
          orchestrate orchestrator: :spec_rec_planner, worker: :spec_rec_worker, max_workers: 2,
                      max_delegation_rounds: 2, task_schema: tasks, worker_output_schema: finding,
                      final_output_schema: summary
          on_failure :fail
        end
      end

      result = nil
      recorder = recorded { result = klass.new(context: {}).run! }
      expect([result.state, result.last_error&.message]).to eq([:done, nil])
      expect(recorder.steps.map { _1["agent"] })
        .to eq(%w[spec_rec_planner spec_rec_worker spec_rec_worker spec_rec_planner])
      expect(recorder.steps.map { _1["attempt_id"] }).to eq(provider_calls.map { _1[:attempt_id] })
      expect_valid_steps(recorder.steps)
    end

    it "records a fallback attempt as failed with kind transient, and an output repair as a second completed step" do
      agent("SpecRecFallbackAgent") { fallback_models model: "claude-haiku-5-5", provider: :anthropic }
      overloaded = { type: "error", error: { type: "overloaded_error", message: "Overloaded" } }
      server.reply(json: overloaded, status: "529 Overloaded").reply(json: message("Open at 8."))
      fallback = recorded { asking("SpecRecFallbackWorkflow").new(context: {}).run! }

      shape = label_schema
      agent("SpecRecRepairAgent") { output_schema shape }
      server.reply(json: message("not json")).reply(json: message('{"label":"bug"}'))
      repair = recorded(described_class.new(trial_spec.trial_id)) do
        asking("SpecRecRepairWorkflow").new(context: {}).run!
      end

      failed, completed = fallback.steps
      expect([failed["outcome"], failed["failure"]["kind"], failed["model"], failed["cost_nanos"],
              failed["cost_known"]])
        .to eq(["failed", "transient", "claude-sonnet-5-5", 0, true])
      expect([completed["outcome"], completed["model"], completed["attempt_index"]])
        .to eq(["completed", "claude-haiku-5-5", 1])
      expect(repair.steps.map { [_1["outcome"], _1["sent_count"], _1["messages"].length] })
        .to eq([["completed", 1, 2], ["completed", 3, 4]])
      expect_valid_steps(fallback.steps + repair.steps)
    end

    it "keeps failure kinds, tokens and tool call names with content off, and no messages" do
      testing.unstubbed = :refuse
      stub_const("SpecRecLookup", Class.new(Smith::Tool) do
        param :query, type: :string, required: true
        define_method(:perform) { |query:| "#{query} opens at 8" }
      end)
      stubbed("SpecRecToolAgent", :spec_ledger_agent, lambda { |request|
        request.round == 1 ? testing.tool_call(SpecRecLookup, query: "clinic") : "It opens at 8."
      }) { tools SpecRecLookup }

      recorder = recorded(described_class.new(trial_spec.trial_id, recording: { content: false })) do
        asking("SpecRecContentOffWorkflow").new(context: {}).run!
      end
      step = recorder.steps.sole
      expect(step.slice("messages", "tool_calls", "tool_call_names", "tokens"))
        .to eq("messages" => nil, "tool_calls" => 1, "tool_call_names" => ["spec_rec_lookup"],
               "tokens" => { "input" => 20, "output" => 10, "cache_read" => 0, "cache_write" => 0, "thinking" => 0 })
      expect(recorder.recording).to eq("complete" => true, "dropped_steps" => 0, "dropped_seq" => nil,
                                       "cut_fields" => 0, "gaps" => ["content_off"])
      expect(recorder.counts).to eq("agent_attempts" => 1, "tool_calls" => 1, "steps_recorded" => 1)
      expect_valid_steps(recorder.steps)
    end

    it "writes Smith's fixed text for a 401, a 402 and a 403, whatever the provider's body says" do
      bodies = { "401 Unauthorized" => "invalid x-api-key sk-live-secret-1",
                 "402 Payment Required" => "card 4242 4242 declined for org-9",
                 "403 Forbidden" => "org-9 may not use claude-sonnet-5-5 with key sk-live-secret-2" }
      agent("SpecRecRefusedAgent")
      steps = bodies.map do |status, text|
        server.reply(json: { type: "error", error: { type: "error", message: text } }, status:)
        recorded(described_class.new(trial_spec.trial_id)) { asking("SpecRecRefusedWorkflow").new(context: {}).run! }
          .steps.sole
      end

      expect(steps.map { _1["failure"].values_at("kind", "message") }).to eq(
        [["key_refused", "the provider refused the key (HTTP 401)"],
         ["out_of_credit", "the provider reports no credit"],
         ["permission", "the key has no permission for this model (HTTP 403)"]]
      )
      # Needles a random attempt id cannot hold.
      expect(JSON.generate(steps)).not_to include("sk-live", "card 4242", "org-9")
      expect_valid_steps(steps)
    end
  end

  describe "when each step started" do
    it "gives sequential steps increasing offsets whose gap covers the first step's time, and overlaps branches" do
      testing.unstubbed = :refuse
      arrived = Queue.new
      both = Queue.new
      stubbed("SpecRecSlowAgent", :spec_rec_slow, lambda { |request|
        sleep 0.03
        "Slow #{request.number}."
      })
      stubbed("SpecRecPairAgent", :spec_rec_pair, lambda { |_request|
        arrived << true
        both.pop(timeout: 5) || raise("the other branch never asked")
        sleep 0.03
        "Together."
      })
      Thread.new do
        2.times { arrived.pop(timeout: 5) }
        2.times { both << true }
      end
      klass = workflow("SpecRecTimedWorkflow") do
        transition(:first, from: :idle, to: :one) { execute :spec_rec_slow }
        transition(:second, from: :one, to: :two) { execute :spec_rec_slow }
        transition :both, from: :two, to: :done do
          execute :spec_rec_pair, parallel: true, count: 2
          on_failure :fail
        end
      end

      steps = recorded { expect(klass.new(context: {}).run!.state).to eq(:done) }.steps
      first, second, left, right = steps
      expect(steps.map { _1["offset_ms"] }).to all(be_a(Integer).and(be >= 0))
      expect(first["duration_ms"]).to be >= 30
      expect(second["offset_ms"] - first["offset_ms"]).to be >= first["duration_ms"]
      expect(left["offset_ms"]).to be >= second["offset_ms"] + second["duration_ms"]
      expect(left["offset_ms"]).to be < right["offset_ms"] + right["duration_ms"]
      expect(right["offset_ms"]).to be < left["offset_ms"] + left["duration_ms"]
      expect_valid_steps(steps)
    end

    it "counts from the recorder's start, so a step begun later has a later offset" do
      testing.unstubbed = :refuse
      stubbed("SpecRecLaterAgent", :spec_ledger_agent)
      recorder = described_class.new(trial_spec.trial_id)
      sleep 0.05
      recorded(recorder) { asking("SpecRecLaterWorkflow").new(context: {}).run! }

      expect(recorder.steps.sole["offset_ms"]).to be >= 50
    end

    # A host may hand a recorder a start after an observation's (a clock
    # read late); an offset is never negative.
    it "gives a step started before the recorder's start an offset of 0" do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      recorder = described_class.new(trial_spec.trial_id, started_at: now)
      recorder.record(observed(1, started: now - 2.5))
      recorder.record(observed(2, started: now + 0.0125))

      expect(recorder.steps.map { _1["offset_ms"] }).to eq([0, 13])
    end
  end

  describe "the settings each step was sent with" do
    def settings_step(temperature: nil, max_output_tokens: nil, thinking: nil)
      observed(1, settings: { temperature:, max_output_tokens:, thinking: })
    end

    # A definition agent's compiled class declares its document's settings
    # through the same agent declarations (slice 1d.2), so its requests
    # carry them as a code agent's do. A stub answers before anything is
    # sent: its step has none.
    it "carries the temperature, output limit and thinking its request carried, null where it carried none" do
      Smith::Agent::Registry.delete(:spec_rec_tuned)
      with_stubbed_class("SpecRecTunedAgent", agent_class) do
        register_as :spec_rec_tuned
        model "claude-sonnet-4-5", provider: :anthropic
        temperature 0.2
        thinking budget: 1024
        params max_tokens: 800
      end
      Smith::Agent::Registry.delete(:spec_rec_plain)
      with_stubbed_class("SpecRecPlainAgent", agent_class) do
        register_as :spec_rec_plain
        model "gpt-4.1", provider: :openai, assume_model_exists: true
      end
      stubbed("SpecRecStubbedAgent", :spec_rec_stubbed) do
        temperature 0.4
        params max_tokens: 200
      end
      klass = workflow("SpecRecSettingsWorkflow") do
        transition(:tuned, from: :idle, to: :one) { execute :spec_rec_tuned }
        transition(:plain, from: :one, to: :two) { execute :spec_rec_plain }
        transition(:stubbed, from: :two, to: :done) { execute :spec_rec_stubbed }
      end
      server.reply(json: message("Tuned."))
            .reply(json: { "id" => "chatcmpl-1", "object" => "chat.completion", "model" => "gpt-4.1",
                           "choices" => [{ "index" => 0, "finish_reason" => "stop",
                                           "message" => { "role" => "assistant", "content" => "Plain." } }],
                           "usage" => { "prompt_tokens" => 10, "completion_tokens" => 2 } })

      steps = recorded { klass.new(context: {}).run! }.steps
      expect(server.requests.first.body.values_at("temperature", "max_tokens", "thinking"))
        .to eq([0.2, 800, { "type" => "enabled", "budget_tokens" => 1024 }])
      expect(steps.map { _1["settings"] }).to eq(
        [{ "temperature" => 0.2, "max_output_tokens" => 800, "thinking" => { "budget" => 1024 } },
         { "temperature" => nil, "max_output_tokens" => nil, "thinking" => nil },
         { "temperature" => nil, "max_output_tokens" => nil, "thinking" => nil }]
      )
      expect_valid_steps(steps)
    end

    it "keeps a thinking effort beside its budget when a request carried both" do
      recorder = described_class.new(trial_spec.trial_id)
      recorder.record(settings_step(temperature: 0, max_output_tokens: 1,
                                    thinking: { effort: "low", budget: 2048 }))
      recorder.record(settings_step(thinking: { effort: :high }))

      expect(recorder.steps.map { _1["settings"] }).to eq(
        [{ "temperature" => 0, "max_output_tokens" => 1, "thinking" => { "effort" => "low", "budget" => 2048 } },
         { "temperature" => nil, "max_output_tokens" => nil, "thinking" => { "effort" => "high" } }]
      )
      expect_valid_steps(recorder.steps)
    end

    # A request's params may carry anything a host wrote: what the trial
    # schema would refuse is null, and the step is kept.
    it "keeps each setting inside the schema, null where the request carried one it would refuse" do
      recorder = described_class.new(trial_spec.trial_id)
      [settings_step(temperature: -0.5, max_output_tokens: 0, thinking: { effort: "x" * 65, budget: 0 }),
       settings_step(temperature: Rational(1, 3), max_output_tokens: 1.5, thinking: { budget: "2048" }),
       settings_step(temperature: Float::NAN, max_output_tokens: "800", thinking: { effort: { level: 1 } }),
       settings_step(temperature: 2**70, max_output_tokens: 2**60,
                     thinking: { effort: "\xFF".b.force_encoding("UTF-8"), budget: 2**53 })]
        .each { recorder.record(_1) }

      expect(recorder.steps.map { _1["settings"] })
        .to eq([{ "temperature" => nil, "max_output_tokens" => nil, "thinking" => nil }] * 4)
      expect_valid_steps(recorder.steps)
    end
  end

  describe "its bounds" do
    it "cuts a long message, tool result and tool call's arguments at their bounds, and marks each cut" do
      testing.unstubbed = :refuse
      stub_const("SpecRecLongLookup", Class.new(Smith::Tool) do
        param :query, type: :string, required: true
        define_method(:perform) { |query:| "#{query.length} letters: #{"result " * 30}" }
      end)
      stubbed("SpecRecLongAgent", :spec_ledger_agent, lambda { |request|
        next testing.tool_call(SpecRecLongLookup, query: "q" * 100) if request.round == 1

        "The answer is #{"long " * 40}"
      }) { tools SpecRecLongLookup }
      bounds = { max_message_bytes: 64, max_tool_bytes: 48 }

      recorder = recorded(described_class.new(trial_spec.trial_id, recording: bounds)) do
        asking("SpecRecLongWorkflow").new(context: {}).run!
      end
      step = recorder.steps.sole
      _user, calling, result, answer = step["messages"]
      expect(calling["tool_calls"].sole.keys).to eq(%w[id name arguments_text])
      expect(calling["tool_calls"].sole["arguments_text"]).to start_with('{"query":"qqq').and end_with("[truncated]")
      expect([calling["cut"], result["cut"], answer["cut"]]).to eq([true, true, true])
      expect([calling["tool_calls"].sole["arguments_text"], result["text"]].map(&:bytesize)).to all(be <= 48)
      expect(answer["text"].bytesize).to be <= 64
      expect(answer["text"]).to start_with("The answer is long").and end_with("...[truncated]")
      expect(step["cut"]).to eq("fields" => 3, "elided_messages" => 0, "content_dropped" => false)
      expect(recorder.recording.slice("complete", "cut_fields")).to eq("complete" => true, "cut_fields" => 3)
      expect_valid_steps(recorder.steps)
    end

    # A memo's replay sent nothing; usage counts the attempts that sent a
    # request (a tool loop's rounds are one).
    it "counts as provider calls the attempts that sent a request, not a skip, a memo's replay or a refusal" do
      recorder = described_class.new(trial_spec.trial_id)
      [observed(1), observed(2, memo: true), observed(3, outcome: :skipped, duration_ms: nil, tokens: nil),
       observed(4, outcome: :aborted, duration_ms: nil, tokens: nil)].each { recorder.record(_1) }

      expect(recorder.usage["provider_calls"]).to eq(1)
      expect(recorder.counts["agent_attempts"]).to eq(4)
    end

    it "marks a text with invalid UTF-8 cut, and counts it" do
      recorder = described_class.new(trial_spec.trial_id)
      text = "caf\xE9 au lait".b.force_encoding("UTF-8")
      recorder.record(observed(1, messages: [{ "role" => "user", "text" => text }]))
      step = recorder.steps.sole

      expect(step["messages"].sole).to include("cut" => true)
      expect([step["messages"].sole["text"].valid_encoding?, step["cut"]["fields"], recorder.recording["cut_fields"]])
        .to eq([true, 1, 1])
      expect_valid_steps(recorder.steps)
    end

    it "keeps the first and last steps when a trial passes max_steps, counting every step it was given" do
      recorder = described_class.new(trial_spec.trial_id, recording: { max_steps: 3 })
      (1..5).each { recorder.record(observed(_1)) }

      expect(recorder.steps.map { _1["seq"] }).to eq([1, 2, 5])
      expect(recorder.steps.map { _1["attempt_id"] }).to eq(%w[attempt-1 attempt-2 attempt-5])
      expect(recorder.recording).to eq("complete" => false, "dropped_steps" => 2, "dropped_seq" => [3, 4],
                                       "cut_fields" => 0, "gaps" => [])
      expect(recorder.counts).to eq("agent_attempts" => 5, "tool_calls" => 0, "steps_recorded" => 3)
      tokens = { "input" => 500, "output" => 100, "cache_read" => 0, "cache_write" => 0, "thinking" => 0 }
      expect(recorder.usage).to eq(
        "tokens" => tokens, "cost_nanos" => 3_000_000, "cost_complete" => true, "provider_calls" => 5,
        "by_model" => [{ "provider" => "anthropic", "model" => "claude-sonnet-5-5", "provider_calls" => 5,
                         "tokens" => tokens, "cost_nanos" => 3_000_000, "cost_complete" => true }]
      )
      expect_valid_steps(recorder.steps)
    end

    # The trial line's usage.by_model (slice 1a.5): the subject's spend by
    # provider and model, from every step it was given, dropped ones too, so
    # it sums to the usage whatever the record kept.
    it "splits its usage by provider and model, dropped steps included, the entries summing to it" do
      recorder = described_class.new(trial_spec.trial_id, recording: { max_steps: 2 })
      recorder.record(observed(1, model: "gpt-5", provider: :openai))
      recorder.record(observed(2))
      recorder.record(observed(3, model: "gpt-5", provider: :openai, outcome: :failed, tokens: nil,
                                  failure: { kind: :transient, error_class: "E", message: "m" }))
      recorder.record(observed(4, model: "claude-unpriced-9", provider: :anthropic))
      recorder.record(observed(5, outcome: :skipped, duration_ms: nil, tokens: nil))
      usage = recorder.usage
      by_model = usage["by_model"]

      expect(recorder.recording["dropped_steps"]).to eq(3)
      expect(by_model.map { _1.values_at("provider", "model", "provider_calls", "cost_complete") })
        .to eq([["anthropic", "claude-sonnet-5-5", 1, true], ["anthropic", "claude-unpriced-9", 1, false],
                ["openai", "gpt-5", 2, true]])
      expect(by_model.map { _1["tokens"]["input"] }).to eq([100, 100, 100])
      %w[cost_nanos provider_calls].each { |key| expect(by_model.sum { _1[key] }).to eq(usage[key]) }
      expect(usage.values_at("provider_calls", "cost_complete")).to eq([4, false])
      expect(usage["tokens"]["input"]).to eq(300)
      expect(EvalsSchema.errors(usage, schema: "common", strict: true, pointer: "#/$defs/usage")).to eq([])
    end

    it "elides messages from the middle of a step past max_step_bytes, keeping the first and the last that fit" do
      messages = (0..9).map { { "role" => _1.zero? ? "system" : "user", "text" => "#{_1} #{"x" * 200}" } }
      recorder = described_class.new(trial_spec.trial_id, recording: { max_step_bytes: 2_000 })
      recorder.record(observed(1, messages:, sent_count: 10))
      step = recorder.steps.sole

      kept = step["messages"].map { _1["text"][0].to_i }
      elided = 10 - kept.length
      expect(kept).to eq([0, *((elided + 1)..9)])
      expect(elided).to be_between(1, 8)
      expect(step["cut"]).to eq("fields" => 0, "elided_messages" => elided, "content_dropped" => false)
      expect(Smith::CanonicalJSON.generate(step).bytesize).to be <= 2_000
      one_more = step.merge("messages" => [messages.first, messages[elided], *step["messages"].drop(1)])
      expect(Smith::CanonicalJSON.generate(one_more).bytesize).to be > 2_000
      expect(recorder.recording["complete"]).to be(false)
      expect_valid_steps(recorder.steps)
    end

    it "drops the messages of steps past max_trial_bytes and keeps their metadata" do
      big = [{ "role" => "user", "text" => "y" * 600 }]
      recorder = described_class.new(trial_spec.trial_id, recording: { max_trial_bytes: 1_500 })
      (1..3).each { recorder.record(observed(_1, messages: big)) }

      expect(recorder.steps.map { _1["messages"]&.length }).to eq([1, nil, nil])
      expect(recorder.steps.map { _1["cut"]["content_dropped"] }).to eq([false, true, true])
      expect(recorder.steps.map { _1["tokens"]["input"] }).to eq([100, 100, 100])
      expect(recorder.recording["complete"]).to be(false)
      expect_valid_steps(recorder.steps)
    end

    # The last steps are the ones a failure is read from: a step the ring
    # drops gives its bytes back to the one that takes its place.
    it "gives the bytes of a step dropped past max_steps to the steps kept after it" do
      big = [{ "role" => "user", "text" => "y" * 600 }]
      recorder = described_class.new(trial_spec.trial_id, recording: { max_steps: 2, max_trial_bytes: 3_000 })
      (1..6).each { recorder.record(observed(_1, messages: big)) }

      expect(recorder.steps.map { _1["seq"] }).to eq([1, 6])
      expect(recorder.steps.map { _1["messages"]&.length }).to eq([1, 1])
      expect(recorder.recording.values_at("dropped_steps", "dropped_seq")).to eq([4, [2, 5]])
      expect_valid_steps(recorder.steps)
    end
  end

  describe "what each step cost" do
    before do
      Smith.config.pricing = Smith.config.pricing.merge(
        %w[openai gpt-image-test] => { input_cost_per_token: 0.000005, output_cost_per_token: 0.00001,
                                       image_input_cost_per_token: 0.00001, image_output_cost_per_token: 0.00004 }
      )
    end

    it "prices a step from its own tokens, by its mode, and an image's image tokens at their own rates" do
      recorder = described_class.new(trial_spec.trial_id)
      recorder.record(observed(1))
      recorder.record(observed(2, mode: :batch))
      image = { input: 40, output: 823, cache_read: nil, cache_write: nil, thinking: nil, image_input: 30,
                image_output: 823 }
      recorder.record(observed(3, model: "gpt-image-test", provider: :openai, tokens: image))

      expect(recorder.steps.map { [_1["cost_nanos"], _1["cost_known"]] })
        .to eq([[600_000, true], [300_000, true], [((10 * 5) + (30 * 10) + (823 * 40)) * 1_000, true]])
    end

    it "rounds a cost to whole nanos half to even" do
      Smith.config.pricing = Smith.config.pricing.merge(
        %w[openai gpt-half-a] => { input_cost_per_token: 0.0000000035, output_cost_per_token: 0 },
        %w[openai gpt-half-b] => { input_cost_per_token: 0.0000000025, output_cost_per_token: 0 }
      )
      one = { input: 1, output: 0, cache_read: nil, cache_write: nil, thinking: nil, image_input: nil,
              image_output: nil }
      recorder = described_class.new(trial_spec.trial_id)
      %w[gpt-half-a gpt-half-b].each_with_index do |model, at|
        recorder.record(observed(at, model:, provider: :openai, tokens: one))
      end

      expect(recorder.steps.map { _1["cost_nanos"] }).to eq([4, 2])
    end

    it "costs nothing for a step that sent nothing or failed unbilled, and an unknown cost otherwise" do
      untokened = { tokens: nil }
      recorder = described_class.new(trial_spec.trial_id)
      [observed(1, **untokened, outcome: :skipped, duration_ms: nil),
       observed(2, **untokened, outcome: :failed),
       observed(3, **untokened, outcome: :aborted, duration_ms: nil),
       observed(4, **untokened, outcome: :aborted),
       observed(5, **untokened),
       observed(6, model: "claude-unpriced-1")].each { recorder.record(_1) }

      expect(recorder.steps.map { [_1["tokens"], _1["cost_nanos"], _1["cost_known"]] })
        .to eq([[nil, 0, true], [nil, 0, true], [nil, 0, true], [nil, nil, false], [nil, nil, false],
                [{ "input" => 100, "output" => 20, "cache_read" => 0, "cache_write" => 0, "thinking" => 0 }, nil,
                 false]])
      expect(recorder.usage.slice("cost_nanos", "cost_complete", "provider_calls"))
        .to eq("cost_nanos" => 0, "cost_complete" => false, "provider_calls" => 4)
      expect_valid_steps(recorder.steps)
    end

    # The provider bills each response alone, and the budget ledger settles
    # each (a usage entry a response): under a tiered price a tool loop's
    # rounds each pick their own tier, never the tier of their sum.
    it "prices each response of an attempt alone, as the ledger does, on the success and the failure path" do
      Smith.config.pricing = Smith.config.pricing.merge(
        %w[anthropic claude-sonnet-5-5] => { tiers: [
          { max_input_tokens: 200_000, input_cost_per_token: 0.000001, output_cost_per_token: 0.000001 },
          { max_input_tokens: nil, input_cost_per_token: 0.000002, output_cost_per_token: 0.000002 }
        ] }
      )
      stub_const("SpecRecTierLookup", Class.new(Smith::Tool) do
        param :query, type: :string, required: true
        define_method(:perform) { |query:| "#{query} opens at 8" }
      end)
      agent("SpecRecTierAgent") { tools SpecRecTierLookup }
      round = message(nil, tokens: [150_000, 10], content: tool_use("spec_rec_tier_lookup"), stop: "tool_use")
      server.reply(json: round).reply(json: message("At 8.", tokens: [150_000, 10]))
            .reply(json: round).reply(json: round)
            .reply(json: { type: "error", error: { type: "overloaded_error", message: "busy" } },
                   status: "529 Overloaded")
      runs = []
      recorder = recorded do
        2.times { runs << asking("SpecRecTierWorkflow").new(context: {}).tap(&:run!) }
      end

      ledger = runs.flat_map(&:usage_entries).group_by(&:attempt_id)
                   .transform_values { |entries| (entries.sum { Rational(_1.cost.to_s) } * 1_000_000_000).round }
      expect(recorder.steps.map { _1.values_at("outcome", "cost_nanos", "cost_known") })
        .to eq([["completed", 300_020_000, true], ["failed", 300_020_000, true]])
      expect(recorder.steps.map { ledger.fetch(_1["attempt_id"]) }).to eq([300_020_000, 300_020_000])
      expect(recorder.steps.map { _1["tokens"]["input"] }).to eq([300_000, 300_000])
      expect(recorder.usage["cost_nanos"]).to eq(600_040_000)
    end

    # A catalog whose last tier is bounded prices nothing above it: a step
    # with one such response has an unknown cost, as its usage entry has.
    it "gives a step an unknown cost when one of its responses has no price" do
      Smith.config.pricing = Smith.config.pricing.merge(
        %w[anthropic claude-sonnet-5-5] => { tiers: [
          { max_input_tokens: 200_000, input_cost_per_token: 0.000001, output_cost_per_token: 0.000001 }
        ] }
      )
      stub_const("SpecRecBoundLookup", Class.new(Smith::Tool) do
        param :query, type: :string, required: true
        define_method(:perform) { |query:| "#{query} opens at 8" }
      end)
      agent("SpecRecBoundAgent") { tools SpecRecBoundLookup }
      server.reply(json: message(nil, tokens: [150_000, 10], content: tool_use("spec_rec_bound_lookup"),
                                      stop: "tool_use"))
            .reply(json: message("At 8.", tokens: [250_000, 10]))
      run = nil
      recorder = recorded { run = asking("SpecRecBoundWorkflow").new(context: {}).tap(&:run!) }

      expect(run.usage_entries.map { _1.cost.nil? }).to eq([false, true])
      expect(recorder.steps.sole.values_at("cost_nanos", "cost_known")).to eq([nil, false])
      expect(recorder.usage.values_at("cost_nanos", "cost_complete")).to eq([0, false])
      expect_valid_steps(recorder.steps)
    end

    # A host that drives a child on the trial's own thread (ajira's drive)
    # keeps the trial's attribution: its steps are recorded and costed,
    # although its usage entries are its own, not the parent's.
    it "prices a run the host drives on the trial's own thread, which the parent's usage leaves out" do
      agent("SpecRecParentAgent")
      server.reply(json: message("Parent.", tokens: [100, 20])).reply(json: message("Child.", tokens: [200, 40]))
      klass = asking("SpecRecDrivenWorkflow")
      parent = nil
      recorder = recorded do
        parent = klass.new(context: {}).tap(&:run!)
        klass.new(context: {}).run!
      end

      expect(parent.usage_entries.length).to eq(1)
      expect(recorder.steps.map { _1["cost_nanos"] }).to eq([600_000, 1_200_000])
      expect(recorder.usage["cost_nanos"]).to eq(1_800_000)
      expect(recorder.recording["gaps"]).to eq([])
    end
  end
end
