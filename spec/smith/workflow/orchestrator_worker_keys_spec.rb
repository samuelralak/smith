# frozen_string_literal: true

require "json"
require "open3"
require "ruby_llm/schema"
require "smith/testing"

# An orchestrate step answered by the local provider server. RubyLLM parses a
# structured reply as JSON, so the orchestrator's decision, its tasks, the
# workers' outputs and the final output reach the step with String keys; a
# host's after_completion may give Symbols instead. Either spelling reads the
# same, and the outputs are kept as the agents gave them. Strict structured
# output gives every decision key, the unused ones null.
RSpec.describe "Smith::Workflow::OrchestratorWorker over a provider's replies" do
  include_context "with a recording budget ledger"

  let(:decision_schema) do
    Class.new do
      def to_json_schema
        text = { type: "string" }
        task = { type: "object", properties: { task_id: text, input: text } }
        final = { type: "object", properties: { summary: text } }
        { name: "decision",
          schema: { type: "object", properties: { tasks: { type: "array", items: task }, final:, stop: text } } }
      end
    end
  end
  # OpenAI's strict mode: every key required, the unused ones null.
  let(:strict_schema) do
    Class.new do
      def to_json_schema
        text = { type: "string" }
        nullable = ->(schema) { { anyOf: [schema, { type: "null" }] } }
        task = { type: "object", properties: { task_id: text, input: text }, required: %w[task_id input],
                 additionalProperties: false }
        final = { type: "object", properties: { summary: text }, required: %w[summary], additionalProperties: false }
        { name: "decision", strict: true,
          schema: { type: "object", required: %w[tasks final stop], additionalProperties: false,
                    properties: { tasks: nullable.call({ type: "array", items: task }), final: nullable.call(final),
                                  stop: nullable.call(text) } } }
      end
    end
  end
  # A RubyLLM::Schema requires every key it names.
  let(:ruby_llm_schema) do
    Class.new(RubyLLM::Schema) do
      any_of :tasks do
        array do
          object do
            string :task_id
            string :input
          end
        end
        null
      end
      any_of :final do
        object do
          string :summary
        end
        null
      end
      any_of :stop do
        string
        null
      end
    end
  end
  let(:finding_schema) do
    Class.new do
      def self.required_keys = %i[finding]

      def to_json_schema
        { name: "finding", schema: { type: "object", properties: { finding: { type: "string" } } } }
      end
    end
  end
  let(:task_schema) { Class.new { def self.required_keys = %i[task_id input] } }
  let(:final_schema) { Class.new { def self.required_keys = %i[summary] } }
  let(:loose_schema) { Class.new { def self.required_keys = [] } }
  let(:symbolized) { ->(result, _context) { result.is_a?(Hash) ? result.transform_keys(&:to_sym) : result } }
  let(:refused) { "orchestrator must emit exactly one of :tasks, :final, or :stop" }

  def agents(orchestrator_completion: nil, schema: decision_schema, **model)
    orchestrator = agent("SpecKeysOrchestrator", register: :spec_keys_orchestrator, **model) { output_schema schema }
    orchestrator.define_method(:after_completion, &orchestrator_completion) if orchestrator_completion
    agent("SpecKeysWorker", register: :spec_keys_worker, **model)
  end

  def orchestrating(name, tasks: task_schema, final: final_schema, **step)
    workers = finding_schema
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "research the pricing" }] }
      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_keys_orchestrator, worker: :spec_keys_worker, max_workers: 2,
                    max_delegation_rounds: 2, task_schema: tasks, worker_output_schema: workers,
                    final_output_schema: final, **step
        on_failure :fail
      end
    end
  end

  def reply(text, id) = server.reply(json: message(text, id:, tokens: [30, 8]))

  # A reply on OpenAI's chat route.
  def chat_reply(text)
    server.reply(json: { "id" => "chatcmpl-1", "object" => "chat.completion", "model" => "gpt-5",
                         "choices" => [{ "index" => 0, "message" => { "role" => "assistant", "content" => text },
                                         "finish_reason" => "stop" }],
                         "usage" => { "prompt_tokens" => 10, "completion_tokens" => 2 } })
  end

  # The text of a request's last message.
  def said(request)
    content = request.body.fetch("messages").last.fetch("content")
    content.is_a?(String) ? content : content.map { _1["text"] }.join
  end

  # The JSON the `index`th request's last message sent, if it was sent.
  def asked(index) = server.requests.drop(index).first(1).map { JSON.parse(said(_1)) }

  def error_of(result) = result.last_error&.message

  it "runs a String-keyed decision's tasks through its workers and ends on its String-keyed final" do
    agents
    reply('{"tasks":[{"task_id":"t1","input":"pricing"}]}', "msg_o1")
    reply('{"finding":"pricing is competitive"}', "msg_w1")
    reply('{"final":{"summary":"competitive"}}', "msg_o2")
    run = orchestrating("SpecKeysTasksWorkflow").new(context: {})

    result = run.run!

    expect([result.state, error_of(result), result.output]).to eq([:done, nil, { "summary" => "competitive" }])
    expect(asked(1)).to eq([{ "task_id" => "t1", "input" => "pricing" }])
    fed_back = server.requests.drop(2).map { JSON.parse(said(_1).split("[smith:worker-results]\n").last) }
    expect(fed_back.flatten.map { _1.slice("task", "output") })
      .to eq([{ "task" => { "task_id" => "t1", "input" => "pricing" },
                "output" => { "finding" => "pricing is competitive" } }])
    expect(run.usage_entries.map(&:agent_name))
      .to eq(%i[spec_keys_orchestrator spec_keys_worker spec_keys_orchestrator])
  end

  it "ends on a String-keyed final from its first round" do
    agents
    reply('{"final":{"summary":"nothing to delegate"}}', "msg_o1")

    result = orchestrating("SpecKeysFinalWorkflow").new(context: {}).run!

    expect([result.state, error_of(result), result.output, server.requests.length])
      .to eq([:done, nil, { "summary" => "nothing to delegate" }, 1])
  end

  it "stops on a String-keyed stop, naming its reason" do
    agents
    reply('{"stop":"not enough signal"}', "msg_o1")

    result = orchestrating("SpecKeysStopWorkflow").new(context: {}).run!

    expect([result.state, error_of(result), server.requests.length])
      .to eq([:failed, "orchestrator stopped: not enough signal", 1])
  end

  it "still refuses a String-keyed decision naming none, or two, of tasks, final and stop" do
    agents
    decisions = ["{}", '{"tasks":[{"task_id":"t1","input":"x"}],"final":{"summary":"done"}}',
                 '{"final":{"summary":"done"},"stop":"halt"}', '{"tasks":[],"stop":"halt"}']
    decisions.each_with_index do |text, index|
      reply(text, "msg_o#{index}")

      result = orchestrating("SpecKeysMalformed#{index}Workflow").new(context: {}).run!

      expect([result.state, error_of(result)]).to eq([:failed, refused]), text
    end
    expect(server.requests.length).to eq(decisions.length)
  end

  it "refuses a decision naming two of them in different spellings" do
    agents(orchestrator_completion: ->(result, _context) { result.merge(tasks: [{ task_id: "t1", input: "x" }]) })
    reply('{"final":{"summary":"done"}}', "msg_o1")

    result = orchestrating("SpecKeysMixedWorkflow").new(context: {}).run!

    expect([result.state, error_of(result), server.requests.length]).to eq([:failed, refused, 1])
  end

  it "gives the workers the Symbol value of a decision key given in both spellings, as 0.16.0 did" do
    from_host = [{ task_id: "t2", input: "from the host" }]
    both = ->(result, _context) { result.key?("tasks") ? result.merge(tasks: from_host) : result }
    agents(orchestrator_completion: both)
    reply('{"tasks":[{"task_id":"t1","input":"from the reply"}]}', "msg_o1")

    orchestrating("SpecKeysBothWaysWorkflow").new(context: {}).run!

    expect(asked(1)).to eq([{ "task_id" => "t2", "input" => "from the host" }])
  end

  it "still fails a String-keyed task or final output that is not a Hash" do
    agents
    reply('{"tasks":["research the pricing"]}', "msg_o1")
    reply('{"final":"competitive"}', "msg_o2")

    results = %w[Task Final].map { orchestrating("SpecKeysNotHash#{_1}Workflow").new(context: {}).run! }

    expect(results.map { [_1.state, error_of(_1)] })
      .to eq([[:failed, "worker task must be a Hash"], [:failed, "final output must be a Hash"]])
  end

  it "still fails a String-keyed task, worker output or final output that misses a required key, naming it" do
    agents
    reply('{"tasks":[{"task_id":"t1"}]}', "msg_o1")
    reply('{"tasks":[{"task_id":"t1","input":"x"}]}', "msg_o2")
    reply("{}", "msg_w2")
    reply('{"final":{}}', "msg_o3")

    results = %w[Task Worker Final].map { orchestrating("SpecKeysMissing#{_1}Workflow").new(context: {}).run! }

    expect(results.map { [_1.state, error_of(_1)] })
      .to eq([[:failed, "worker task missing required keys: input"],
              [:failed, "worker output missing required keys: finding"],
              [:failed, "final output missing required keys: summary"]])
  end

  describe "inside a decision whose own keys are Symbols (an orchestrator's after_completion)" do
    it "checks a worker's String-keyed output against worker_output_schema" do
      agents(orchestrator_completion: symbolized)
      reply('{"tasks":[{"task_id":"t1","input":"pricing"}]}', "msg_o1")
      reply('{"finding":"pricing is competitive"}', "msg_w1")
      reply('{"final":{}}', "msg_o2")

      result = orchestrating("SpecKeysWorkerOutputWorkflow", tasks: loose_schema, final: loose_schema)
               .new(context: {}).run!

      expect([result.state, error_of(result), server.requests.length]).to eq([:done, nil, 3])
    end

    it "checks a String-keyed task against task_schema" do
      agents(orchestrator_completion: symbolized)
      reply('{"tasks":[{"task_id":"t1","input":"pricing"}]}', "msg_o1")
      reply('{"finding":"pricing is competitive"}', "msg_w1")
      reply('{"final":{}}', "msg_o2")

      result = orchestrating("SpecKeysTaskWorkflow", final: loose_schema).new(context: {}).run!

      expect([result.state, error_of(result), asked(1)])
        .to eq([:done, nil, [{ "task_id" => "t1", "input" => "pricing" }]])
    end

    it "checks a String-keyed final against final_output_schema and keeps it as given" do
      agents(orchestrator_completion: symbolized)
      reply('{"final":{"summary":"competitive"}}', "msg_o1")

      result = orchestrating("SpecKeysFinalOutputWorkflow").new(context: {}).run!

      expect([result.state, error_of(result), result.output]).to eq([:done, nil, { "summary" => "competitive" }])
    end

    it "reads Symbol-keyed tasks and final against schemas that name String keys" do
      deep = ->(result, _context) { JSON.parse(JSON.generate(result), symbolize_names: true) }
      agents(orchestrator_completion: deep)
      reply('{"tasks":[{"task_id":"t1","input":"pricing"}]}', "msg_o1")
      reply('{"finding":"pricing is competitive"}', "msg_w1")
      reply('{"final":{"summary":"competitive"}}', "msg_o2")
      strings = ->(*keys) { Class.new { define_singleton_method(:required_keys) { keys } } }

      result = orchestrating("SpecKeysStringSchemaWorkflow", tasks: strings.call("task_id", "input"),
                                                             final: strings.call("summary")).new(context: {}).run!

      expect([result.state, error_of(result), result.output]).to eq([:done, nil, { summary: "competitive" }])
    end
  end

  describe "a decision that gives its unused keys as null (strict structured output)" do
    let(:openai) { { model: "gpt-5", provider: :openai } }

    it "ends on a final whose siblings are null, on OpenAI's strict route" do
      agents(schema: strict_schema, **openai)
      chat_reply('{"tasks":null,"final":{"summary":"competitive"},"stop":null}')

      result = orchestrating("SpecKeysStrictFinalWorkflow").new(context: {}).run!

      sent = server.requests.first.body.dig("response_format", "json_schema")
      expect([sent["strict"], sent.dig("schema", "required")]).to eq([true, %w[tasks final stop]])
      expect([result.state, error_of(result), result.output]).to eq([:done, nil, { "summary" => "competitive" }])
    end

    it "runs tasks whose siblings are null, then their final, on OpenAI's strict route" do
      agents(schema: strict_schema, **openai)
      chat_reply('{"tasks":[{"task_id":"t1","input":"pricing"}],"final":null,"stop":null}')
      chat_reply('{"finding":"pricing is competitive"}')
      chat_reply('{"tasks":null,"final":{"summary":"competitive"},"stop":null}')

      result = orchestrating("SpecKeysStrictTasksWorkflow").new(context: {}).run!

      expect([result.state, error_of(result), result.output, asked(1)])
        .to eq([:done, nil, { "summary" => "competitive" }, [{ "task_id" => "t1", "input" => "pricing" }]])
    end

    it "runs a RubyLLM::Schema decision, which requires all three keys" do
      agents(schema: ruby_llm_schema)
      reply('{"tasks":[{"task_id":"t1","input":"pricing"}],"final":null,"stop":null}', "msg_o1")
      reply('{"finding":"pricing is competitive"}', "msg_w1")
      reply('{"tasks":null,"final":null,"stop":"enough signal"}', "msg_o2")

      result = orchestrating("SpecKeysRubyLLMSchemaWorkflow").new(context: {}).run!

      expect(server.requests.first.body.dig("output_config", "format", "schema", "required"))
        .to eq(%w[tasks final stop])
      expect([result.state, error_of(result), server.requests.length])
        .to eq([:failed, "orchestrator stopped: enough signal", 3])
    end

    it "still refuses a decision in which none, or two, of the three hold a value" do
      agents
      decisions = ['{"tasks":null,"final":null,"stop":null}', '{"final":null}',
                   '{"tasks":[],"final":{"summary":"done"},"stop":null}',
                   '{"tasks":null,"final":{"summary":"done"},"stop":"halt"}']
      decisions.each_with_index do |text, index|
        reply(text, "msg_o#{index}")

        result = orchestrating("SpecKeysNull#{index}Workflow").new(context: {}).run!

        expect([result.state, error_of(result)]).to eq([:failed, refused]), text
      end
      expect(server.requests.length).to eq(decisions.length)
    end

    it "counts a key holding false as given, since it holds a value" do
      agents
      reply('{"final":{"summary":"done"},"stop":false}', "msg_o1")
      reply('{"stop":false}', "msg_o2")

      results = %w[Both Alone].map { orchestrating("SpecKeysFalse#{_1}Workflow").new(context: {}).run! }

      expect(results.map { [_1.state, error_of(_1)] })
        .to eq([[:failed, refused], [:failed, "orchestrator stopped: false"]])
    end

    it "reads a key given both ways by its Symbol value, so a null there names nothing" do
      symbol_null = ->(result, _context) { result.key?("tasks") ? result.merge(tasks: nil) : result }
      agents(orchestrator_completion: symbol_null)
      reply('{"tasks":[{"task_id":"t1","input":"pricing"}]}', "msg_o1")

      result = orchestrating("SpecKeysSymbolNullWorkflow").new(context: {}).run!

      expect([result.state, error_of(result), server.requests.length]).to eq([:failed, refused, 1])
    end

    it "counts only the keys a decision has, never its Hash's default value" do
      defaulted = ->(result, _context) { Hash.new { "a default" }.merge(result) }
      agents(orchestrator_completion: defaulted)
      reply('{"final":{"summary":"competitive"}}', "msg_o1")

      result = orchestrating("SpecKeysDefaultWorkflow").new(context: {}).run!

      expect([result.state, error_of(result), result.output]).to eq([:done, nil, { "summary" => "competitive" }])
    end

    it "keeps 0.16.0's answers for nulls inside tasks, worker outputs and the final output" do
      agents
      reply('{"tasks":[{"task_id":"t1","input":null}]}', "msg_o1")
      reply('{"finding":null}', "msg_w1")
      reply('{"final":{"summary":null}}', "msg_o2")
      reply('{"tasks":[null]}', "msg_o3")
      reply('{"tasks":[{"task_id":"t1","input":"pricing"}]}', "msg_o4")
      reply("null", "msg_w4")

      results = %w[Kept Task Worker].map { orchestrating("SpecKeysNulls#{_1}Workflow").new(context: {}).run! }

      expect(results.map { [_1.state, _1.output, error_of(_1)] }.first(2))
        .to eq([[:done, { "summary" => nil }, nil], [:failed, nil, "worker task must be a Hash"]])
      expect([results.last.state, results.last.last_error.class, server.requests.length])
        .to eq([:failed, Smith::BlankAgentOutputError, 6])
    end
  end

  it "runs on Smith::Testing stubs, whose Hash outputs reach it as JSON replies" do
    agents
    decisions = [{ tasks: [{ task_id: "t1", input: "pricing" }] }, { final: { summary: "done" } }]
    Smith::Testing.stub_agent(:spec_keys_orchestrator, outputs: decisions)
    Smith::Testing.stub_agent(:spec_keys_worker, outputs: { finding: "pricing is competitive" })

    result = orchestrating("SpecKeysTestingWorkflow").new(context: {}).run!

    expect([result.state, error_of(result), result.output, server.requests])
      .to eq([:done, nil, { "summary" => "done" }, []])
  ensure
    Smith::Testing.reset!
  end

  describe "a durable run cut mid-orchestration" do
    # The process dies once, when the memo keeps its `die_after`th whole call.
    let(:crash) { Class.new(Exception) } # rubocop:disable Lint/InheritException
    let(:memo) do
      Class.new do
        attr_accessor :crash, :die_after

        def initialize = @records = {}
        def fetch(key) = @records[key]

        def store(key, record)
          @records[key] = record
          dies = crash
          return unless dies && record["complete"] && @records.values.count { _1["complete"] } == die_after

          self.crash = nil
          raise dies
        end
      end.new
    end
    let(:adapter) { Smith::PersistenceAdapters::Memory.new }

    around do |example|
      saved = Smith.config.response_memo
      example.run
    ensure
      Smith.config.response_memo = saved
    end

    before { Smith.config.response_memo = memo }

    it "restores, replays its kept String-keyed calls from the response memo and finishes" do
      agents
      reply('{"tasks":[{"task_id":"t1","input":"pricing"}]}', "msg_o1")
      reply('{"finding":"pricing is competitive"}', "msg_w1")
      reply('{"final":{"summary":"competitive"}}', "msg_o2")
      memo.crash = crash
      memo.die_after = 2
      klass = orchestrating("SpecKeysDurableWorkflow", output_to: :report)

      cut = begin
        result = klass.new(context: {}).run_persisted!("run-keys", adapter:)
        [result.state, error_of(result)]
      rescue crash
        :cut
      end
      expect(cut).to eq(:cut)
      expect(server.requests.length).to eq(2)
      done = klass.restore("run-keys", adapter:).run_persisted!("run-keys", adapter:)

      expect([done.state, done.output, server.requests.length]).to eq([:done, { "summary" => "competitive" }, 3])
      expect(done.usage_entries.map(&:agent_name))
        .to eq(%i[spec_keys_orchestrator spec_keys_worker spec_keys_orchestrator])
      expect(klass.restore("run-keys", adapter:).to_state[:context][:report]).to eq(summary: "competitive")
    end
  end

  # In a fresh process: a constant Smith keeps under one of these classes is
  # found by a bare name in every host subclass before the host's own.
  it "leaves a host's own top-level OutputKeys to its Smith subclasses' bodies and methods" do
    script = <<~RUBY
      require "json"
      require "smith"

      module OutputKeys; end

      class HostWorkflow < Smith::Workflow
        BODY = OutputKeys
        def from_method = OutputKeys
      end

      class HostAgent < Smith::Agent
        BODY = OutputKeys
        def from_method = OutputKeys
      end

      class HostContext < Smith::Context
        BODY = OutputKeys
        def from_method = OutputKeys
      end

      class HostTool < Smith::Tool
        BODY = OutputKeys
        def from_method = OutputKeys
      end

      found = [HostWorkflow, HostAgent, HostContext, HostTool].to_h do |host|
        [host.superclass.name, [host::BODY, host.allocate.from_method].map { _1.equal?(::OutputKeys) ? "host" : _1.name }]
      end
      puts JSON.generate(found)
    RUBY
    lib = File.expand_path("../../../lib", __dir__)
    out, status = Open3.capture2e(RbConfig.ruby, "-I#{lib}", "-e", script)

    expect([status.success?, out.lines.last.to_s.strip])
      .to eq([true, JSON.generate(%w[Workflow Agent Context Tool].to_h { ["Smith::#{_1}", %w[host host]] })])
  end
end
