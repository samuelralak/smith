# frozen_string_literal: true

# What a batch result does when its step renders another request by the time
# it comes (`on_request_change:`): :keep it (the default), :resend the
# request over the wire, or :fail the step.
RSpec.describe "Smith batch mode: a request changed while it waited" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:queue_class) do
    Class.new do
      attr_reader :items

      def initialize = @items = []
      def enqueue(**request) = @items << request
    end
  end
  let(:queue) { queue_class.new }
  let(:server) { SseServer.new }
  let(:today) { +"Monday" }

  around do |example|
    saved_queue = Smith.config.batch_queue
    config = RubyLLM.config
    saved = %i[anthropic_api_key anthropic_api_base].to_h { [_1, config.public_send(_1)] }
    example.run
  ensure
    server.close
    saved.each { |key, value| config.public_send(:"#{key}=", value) }
    Smith.config.batch_queue = saved_queue
  end

  before do
    RubyLLM.configure do |config|
      config.anthropic_api_key = "test"
      config.anthropic_api_base = server.url
    end
    Smith.config.batch_queue = queue
    allow_any_instance_of(workflow_class).to receive(:sleep)
  end

  def message(text, id: "msg_b", tokens: [5, 2])
    { "id" => id, "type" => "message", "role" => "assistant", "model" => "claude-sonnet-5-5",
      "content" => [{ "type" => "text", "text" => text }], "stop_reason" => "end_turn",
      "usage" => { "input_tokens" => tokens.first, "output_tokens" => tokens.last } }
  end

  def succeeded(text, **) = { "type" => "succeeded", "message" => message(text, **) }

  # An agent whose prompt reads the day.
  def dated_agent(name, register)
    Smith::Agent::Registry.delete(register)
    day = today
    with_stubbed_class(name, agent_class) do
      register_as register
      model "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true
      instructions { "Today is #{day}." }
    end
  end

  def asking(name, mode: :batch, **opts, &body)
    dated_agent("#{name}Agent", :spec_change_agent)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "what day is it?" }] }
      transition :ask, from: :idle, to: :done do
        execute :spec_change_agent, mode:, output_to: :answer, **opts
        instance_exec(&body) if body
        on_failure :fail
      end
    end
  end

  def deliver(workflow, text = "Monday, from the batch")
    token = workflow.awaiting.token
    items = queue.items.select { _1[:await_token] == token }
    workflow.resume!(event: :batch_result, token:, payload: items.to_h { [_1[:custom_id], succeeded(text)] })
  end

  def kinds(workflow) = workflow.usage_entries.map { [_1.mode, _1.attempt_kind] }

  it "resends a changed request over the wire, and charges the batch result it set aside" do
    workflow = asking("SpecChangeResendWorkflow", on_request_change: :resend).new(context: {})
    workflow.run!
    today.replace("Tuesday")
    server.reply(json: message("Tuesday, over the wire", id: "msg_wire", tokens: [6, 3]))

    expect(deliver(workflow)).to eq(:resumed)
    expect([workflow.state, workflow.to_state[:context][:answer]]).to eq([:done, "Tuesday, over the wire"])
    expect(server.requests.sole.body.to_json).to include("Today is Tuesday.")
    expect(kinds(workflow)).to contain_exactly(%i[batch failed_attempt], [nil, :completed_attempt])
  end

  it "takes an unchanged request's result under :resend, sending nothing" do
    workflow = asking("SpecChangeSameWorkflow", on_request_change: :resend).new(context: {})
    workflow.run!

    expect(deliver(workflow)).to eq(:resumed)
    expect([workflow.to_state[:context][:answer], server.requests]).to eq(["Monday, from the batch", []])
    expect(kinds(workflow)).to eq([%i[batch completed_attempt]])
  end

  it "fails a changed request's step under :fail, which retry_on may send again synchronously" do
    failing = asking("SpecChangeFailWorkflow", on_request_change: :fail).new(context: {})
    failing.run!
    today.replace("Tuesday")

    expect(deliver(failing)).to eq(:failed)
    expect(failing.to_state[:last_failed_step]).to include(error_class: "Smith::BatchRequestChanged")
    expect(kinds(failing)).to eq([%i[batch failed_attempt]])

    today.replace("Monday")
    switch = ->(_context, attempt) { attempt == 1 ? :batch : :sync }
    retrying = asking("SpecChangeRetryWorkflow", mode: switch, on_request_change: :fail) do
      retry_on attempts: 2, backoff: 1
    end.new(context: {})
    retrying.run!
    today.replace("Tuesday")
    server.reply(json: message("Tuesday, over the wire", id: "msg_wire"))
    expect(deliver(retrying)).to eq(:resumed)
    expect([retrying.state, retrying.to_state[:context][:answer]]).to eq([:done, "Tuesday, over the wire"])
  end

  it "resends only the fan-out branch whose request changed" do
    dated_agent("SpecChangeDetectAgent", :spec_change_detect)
    Smith::Agent::Registry.delete(:spec_change_extract)
    with_stubbed_class("SpecChangeExtractAgent", agent_class) do
      register_as :spec_change_extract
      model "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true
    end
    klass = with_stubbed_class("SpecChangeFanWorkflow", workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "read" }] }
      transition :read, from: :idle, to: :done do
        fan_out branches: { detect: :spec_change_detect, extract: :spec_change_extract }, mode: :batch,
                on_request_change: :resend, output_to: :read
        on_failure :fail
      end
    end
    workflow = klass.new(context: {})
    workflow.run!
    today.replace("Tuesday")
    server.reply(json: message("detected again", id: "msg_wire"))

    expect(deliver(workflow, "from the batch")).to eq(:resumed)
    outputs = workflow.to_state[:context][:read].to_h { [_1[:branch], _1[:output]] }
    expect(outputs).to eq("detect" => "detected again", "extract" => "from the batch")
    expect(server.requests.length).to eq(1)
  end

  it "is declared only on a step that may batch, and shows in graph inspection" do
    expect { asking("SpecChangeBadWorkflow", on_request_change: :retry) }
      .to raise_error(Smith::WorkflowError, /must be :keep, :resend or :fail/)
    expect { asking("SpecChangeSyncWorkflow", mode: :sync, on_request_change: :resend) }
      .to raise_error(Smith::WorkflowError, /needs mode: :batch/)
    klass = asking("SpecChangeShownWorkflow", on_request_change: :resend)
    transition = klass.transition_named(:ask)
    expect(transition.agent_opts).not_to have_key(:on_request_change)
    snapshot = klass.graph.transition_snapshots.find { _1.name == :ask }
    expect([snapshot.mode, snapshot.on_request_change]).to eq(%i[batch resend])
  end
end
