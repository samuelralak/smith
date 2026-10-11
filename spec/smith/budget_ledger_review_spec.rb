# frozen_string_literal: true

require "base64"

# What two reviews of budget ledgers found (slice 12), each pinned.
RSpec.describe "Smith budget ledgers: review fixes" do
  include_context "with a recording budget ledger"

  let(:responses_reply) do
    { "id" => "resp_1", "object" => "response", "model" => "gpt-5", "status" => "completed",
      "output" => [{ "type" => "message", "role" => "assistant",
                     "content" => [{ "type" => "output_text", "text" => "paid" }] }],
      "usage" => { "input_tokens" => 300, "output_tokens" => 200 } }
  end

  it "holds a request OpenAI's Responses route sends, once, and refuses it before it is sent" do
    agent("SpecLedgerResponsesAgent", model: "gpt-5", provider: :openai) { params openai_api_mode: :responses }
    refusing = ledger_class.new(admit: false)
    refused = asking("SpecLedgerResponsesRefused") { |_scope| refusing }.new(context: {}).run!
    expect([refused.state, server.requests, refusing.kinds]).to eq([:failed, [], [:reserve]])

    server.reply(json: responses_reply)
    held = ledger
    result = asking("SpecLedgerResponsesWorkflow") { |_scope| held }.new(context: {}).run!
    expect([result.output, server.requests.map(&:path)]).to eq(["paid", ["/v1/responses"]])
    expect(ledger.kinds).to eq(%i[reserve reconcile])
    expect(ledger.calls.last[2]).to eq(amount(300, 200, (300 * 0.000003) + (200 * 0.000015)))
  end

  it "holds a plain OpenAI request once, though both its class and the base class are hooked" do
    agent("SpecLedgerChatAgent", model: "gpt-5", provider: :openai)
    server.reply(json: { "id" => "chatcmpl-1", "object" => "chat.completion", "model" => "gpt-5",
                         "choices" => [{ "index" => 0, "message" => { "role" => "assistant", "content" => "fit" },
                                         "finish_reason" => "stop" }],
                         "usage" => { "prompt_tokens" => 10, "completion_tokens" => 2 } })
    held = ledger
    result = asking("SpecLedgerChatWorkflow") { |_scope| held }.new(context: {}).run!
    expect([result.output, server.requests.map(&:path), ledger.kinds])
      .to eq(["fit", ["/v1/chat/completions"], %i[reserve reconcile]])
  end

  it "builds a run's ledger once for all its branches, and holds no later round of a step that retries other errors" do
    %i[spec_ledger_left spec_ledger_right].each { |register| agent("Spec#{register}B", register:) }
    built = 0
    held = ledger
    fanned = with_stubbed_class("SpecLedgerOnceWorkflow", workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger { |_scope| (built += 1) && held }
      seed_messages { |_context| [{ role: :user, content: "read" }] }
      transition :read, from: :idle, to: :done do
        fan_out branches: { left: :spec_ledger_left, right: :spec_ledger_right }
        on_failure :fail
      end
    end
    server.reply(json: message("one")).reply(json: message("two"))
    expect([fanned.new(context: {}).run!.state, built]).to eq([:done, 1])

    stub_const("SpecLedgerOtherLookup", Class.new(Smith::Tool) do
      param :query, type: :string, required: true
      def perform(query:) = { found: query }
    end)
    agent("SpecLedgerOtherAgent") { tools SpecLedgerOtherLookup }
    other = ledger_class.new
    retrying = asking("SpecLedgerOtherRetry") { |_scope| other }
    retrying.transition_named(:ask).retry_on(IOError, attempts: 2)
    server.reply(json: message(nil, id: "msg_a", content: tool_use("spec_ledger_other_lookup"), stop: "tool_use"))
          .reply(json: message("done", id: "msg_b"))
    expect(retrying.new(context: {}).run!.output).to eq("done")
    expect(other.kinds).to eq(%i[reserve reconcile reconcile])
  end

  it "prices a batch result under the id RubyLLM resolves the agent's model to, as its hold and usage are" do
    Smith.config.pricing = { %w[anthropic claude-sonnet-4-5-20250929] => prices }
    Smith.config.batch_queue = queue = batch_queue
    Smith::Agent::Registry.delete(:spec_ledger_agent)
    with_stubbed_class("SpecLedgerAliasAgent", agent_class) do
      register_as :spec_ledger_agent
      model "claude-sonnet-4-5", provider: :anthropic
      params max_tokens: 500
    end
    held = ledger
    workflow = asking("SpecLedgerAliasWorkflow", mode: :batch) { |_scope| held }.new(context: {})
    workflow.run!
    reply = message("x").merge("model" => "claude-sonnet-4-5-20250929")
    workflow.resume!(event: :batch_result, token: workflow.awaiting.token,
                     payload: { queue.items.last[:custom_id] => { "type" => "succeeded", "message" => reply } })

    hold, settled = ledger.calls.values_at(0, -1)
    expect([hold[2].cost.nil?, settled.first, settled[2].cost])
      .to eq([false, :reconcile, ((100 * 0.000003) + (20 * 0.000015)) * 0.5])
    expect(workflow.usage_entries.last.cost).to eq(settled[2].cost)
    codes = asking("SpecLedgerAliasReadiness") { |_scope| nil }.runtime_readiness.runtime_diagnostics.map(&:code)
    expect(codes).not_to include(:budget_ledger_unpriced)
  end

  it "charges a run its own class's ledger: an inline child run never charges its parent's" do
    agent("SpecLedgerKidAgent")
    server.reply(json: message("child"))
    Smith.config.run_launcher = Smith::Launchers::Inline.new
    kid = asking("SpecLedgerKidWorkflow")
    held = ledger
    parent = with_stubbed_class("SpecLedgerInlineParent", workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger { |_scope| held }
      transition :fan, from: :idle, to: :done do
        map :ids, workflow: kid, max_items: 1, timeout: 60, input: ->(id, _ctx) { { id: } }, into: :results
        on_failure :fail
      end
    end

    expect(parent.new(context: { ids: %w[a] }).run!.state).to eq(:done)
    expect([ledger.kinds, server.requests.length]).to eq([[], 1])
  end

  it "settles a batch hold on the ledger it was taken on, whatever a step writes to the context meanwhile" do
    Smith.config.batch_queue = queue = batch_queue
    agent("SpecLedgerAcctAgent")
    ledgers = { "a" => ledger_class.new, "b" => ledger_class.new }
    klass = with_stubbed_class("SpecLedgerAcctWorkflow", workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger(:account) { |scope| ledgers.fetch(scope[:account]) }
      seed_messages { |_context| [{ role: :user, content: "read" }] }
      transition(:switch, from: :idle, to: :switched) { compute { |step| step.write_context(:account, "b") } }
      transition :ask, from: :switched, to: :done do
        execute :spec_ledger_agent, mode: :batch
        on_failure :fail
      end
    end
    adapter = Smith::PersistenceAdapters::Memory.new
    klass.new(context: { account: "a" }).run_persisted!("run-acct", adapter:)
    waiting = klass.restore("run-acct", adapter:).awaiting
    result = { "type" => "succeeded", "message" => message("x") }
    klass.resume!("run-acct", event: :batch_result, token: waiting.token, adapter:,
                              payload: { queue.items.last[:custom_id] => result })

    expect([ledgers["a"].kinds, ledgers["b"].kinds]).to eq([%i[reserve reconcile], []])
  end

  it "keeps the hold of a request the queue took before it failed, and releases only the rest" do
    %i[spec_ledger_l spec_ledger_r].each { |register| agent("Spec#{register}Q", register:) }
    queue = Class.new do
      attr_reader :items

      def initialize = @items = []

      def enqueue(**request)
        raise IOError, "queue down" if @items.length == 1

        @items << request
      end
    end.new
    Smith.config.batch_queue = queue
    held = ledger
    klass = with_stubbed_class("SpecLedgerQueueWorkflow", workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger { |_scope| held }
      seed_messages { |_context| [{ role: :user, content: "read" }] }
      transition :read, from: :idle, to: :done do
        fan_out branches: { l: :spec_ledger_l, r: :spec_ledger_r }, mode: :batch
        on_failure :fail
      end
    end

    expect(klass.new(context: {}).run!.state).to eq(:failed)
    released = ledger.calls.select { _1.first == :release }.map { _1[1] }
    expect([released.length, released & queue.items.map { _1[:custom_id] }]).to eq([1, []])
  end

  it "reconciles at its hold a reply without usage, and a stream that failed after it began" do
    agent("SpecLedgerNoUsageAgent")
    bare = message("paid").except("usage")
    server.reply(json: bare)
    held = ledger
    expect(asking("SpecLedgerNoUsageWorkflow") { |_scope| held }.new(context: {}).run!.output).to eq("paid")
    expect(ledger.calls.last).to eq([:reconcile, ledger.keys.first, ledger.calls.first[2]])

    sink = Class.new { %i[start delta reset finish fail withdraw].each { |name| define_method(name) { |*| nil } } }
    allow(Smith.config).to receive(:stream_sinks).and_return(reply: ->(_info) { sink.new })
    server.reply(events: [
                   { type: "message_start",
                     message: { id: "msg_s", model: "m", usage: { input_tokens: 5000, output_tokens: 1 } } },
                   { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
                   { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "streamed" } },
                   { type: "error", error: { type: "overloaded_error", message: "Overloaded" } }
                 ])
    streamed = ledger_class.new
    asking("SpecLedgerBrokenStreamWorkflow", stream: :reply) { |_scope| streamed }.new(context: {}).run!
    expect(streamed.kinds).to eq(%i[reserve reconcile])
    expect(streamed.calls.last[2]).to eq(streamed.calls.first[2])

    negative = message("odd")
    negative["usage"]["output_tokens"] = -3
    server.reply(json: negative)
    odd = ledger_class.new
    expect(asking("SpecLedgerOddWorkflow") { |_scope| odd }.new(context: {}).run!.output).to eq("odd")
    expect(odd.calls.last[2].output_tokens).to eq(0)
  end

  it "warns of unpriced models wherever the ledger is charged, and shows the ledger in readiness" do
    agent("SpecLedgerGen", register: :spec_ledger_gen, model: "claude-unpriced-1")
    agent("SpecLedgerEval", register: :spec_ledger_eval)
    optimizing = with_stubbed_class("SpecLedgerOptimizeWorkflow", workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger(:account) { |_scope| nil }
      transition :improve, from: :idle, to: :done do
        optimize generator: :spec_ledger_gen, evaluator: :spec_ledger_eval, max_rounds: 2,
                 evaluator_schema: Struct.new(:required_keys).new([:accept])
        on_failure :fail
      end
    end
    report = optimizing.runtime_readiness
    expect(report.runtime_diagnostics.map { [_1.code, _1.target] }).to eq([%i[budget_ledger_unpriced spec_ledger_gen]])
    expect(report.metrics[:budget_ledger]).to eq(scope_keys: [:account])

    child = asking("SpecLedgerNestedChild", agent: :spec_ledger_gen)
    parent = with_stubbed_class("SpecLedgerNestedParent", workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger { |_scope| nil }
      transition(:nest, from: :idle, to: :done) do
        workflow child
        on_failure :fail
      end
    end
    expect(parent.runtime_readiness.runtime_diagnostics.map(&:code)).to include(:budget_ledger_unpriced)
    expect(asking("SpecLedgerPlainReadiness").runtime_readiness.metrics[:budget_ledger]).to be_nil
  end

  it "counts an image or a PDF in raw content as an attachment, not as its base64 text" do
    png = Base64.strict_encode64("\x89PNG\r\n\x1a\n".b + Random.new(1).bytes(300_000))
    pdf = "%PDF-1.4\n<< /Type /Pages >>\n<< /Type /Page >>\n<< /Type/Page >>\n<< /Type /Page >>\n".b
    raw = RubyLLM::Content::Raw.new([{ type: "image", source: { type: "base64", media_type: "image/png", data: png } },
                                     { type: "document", source: { type: "base64", media_type: "application/pdf",
                                                                   data: Base64.strict_encode64(pdf) } }])
    estimate = Smith::Budget::RequestHold.method(:input_estimate)
    linked = RubyLLM::Content::Raw.new([{ type: "image", source: { type: "url", url: "https://example.test/a.png" } }])
    expect(estimate.call([RubyLLM::Message.new(role: :user, content: linked)], {}, nil)).to eq(1_600 + 8)
    expect(estimate.call([RubyLLM::Message.new(role: :user, content: raw)], {}, nil)).to eq(1_600 + (3 * 2_000) + 8)
    url = "data:application/pdf;base64,#{Base64.strict_encode64("%PDF-1.4 #{"x" * 120_000}")}"
    expect(estimate.call([RubyLLM::Message.new(role: :user, content: url)], {}, nil)).to eq((3 * 2_000) + 8)
    csv = Base64.strict_encode64("a" * 30)
    inline = RubyLLM::Content::Raw.new([{ inline_data: { mime_type: "text/csv", data: csv } }])
    expect(estimate.call([RubyLLM::Message.new(role: :user, content: inline)], {}, nil)).to eq(10 + 8)
  end

  it "notes no hold for a batch capture when the step has no ledger" do
    Smith.config.batch_queue = batch_queue
    agent("SpecLedgerNoHoldAgent")
    allow(Smith::Budget::RequestHold).to receive(:for_request).and_call_original
    asking("SpecLedgerNoHoldWorkflow", mode: :batch).new(context: {}).run!

    expect(Smith::Budget::RequestHold).not_to have_received(:for_request)
  end
end
