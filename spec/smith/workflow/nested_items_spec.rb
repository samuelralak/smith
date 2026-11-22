# frozen_string_literal: true

# A fan-out over items (0.16.0): `workflow Child, over:, item_to:` runs one
# nested run an item, each with its own item and its own outcome, a refused
# run an outcome rather than the step's failure, at most `concurrency:` at once.
RSpec.describe "Smith::Workflow fan-out over items" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }

  def refusal = Smith::OutputRefused.new(agent_name: :spec_drawer, model_used: "m", stop_reason: "moderation_blocked")

  # An agent answering each request with what `work` makes of its item, read
  # back from the request's words.
  def drawer(&work)
    Smith::Agent::Registry.delete(:spec_items_drawer)
    klass = with_stubbed_class("SpecItemsDrawer", agent_class) do
      register_as :spec_items_drawer
      model "gpt-5-mini", provider: :openai, assume_model_exists: true
    end
    allow(klass).to receive(:chat) { answering_chat(work) }
    klass
  end

  def answering_chat(work)
    chat = Object.new
    asked = []
    chat.define_singleton_method(:add_message) { |message| asked << message }
    chat.define_singleton_method(:complete) do
      Struct.new(:content, :input_tokens, :output_tokens).new(work.call(JSON.parse(asked.last[:content].to_s)), 5, 3)
    end
    chat
  end

  def child(name, failure_route: true, &work)
    drawer(&work)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :work, from: :idle, to: :done do
        execute :spec_items_drawer, input: ->(context) { [{ role: :user, content: JSON.generate(context[:pose]) }] }
        on_failure :fail if failure_route
      end
    end
  end

  def parent(name, nested, items:, concurrency: nil)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :drawn
      state :failed

      transition :draw, from: :idle, to: :drawn do
        workflow nested, over: ->(context) { context[:poses] || items }, item_to: :pose,
                         concurrency:, output_to: :frames
        on_failure :fail
      end
    end
  end

  it "runs one nested run an item, each with its own item, its outcomes in the items' order" do
    nested = child("SpecItemsChild") { |pose| "drew #{pose}" }
    result = parent("SpecItemsParent", nested, items: [1, 2, 3]).new(context: {}).run!

    expect(result.state).to eq(:drawn)
    expect(result.context[:frames]).to eq([{ output: "drew 1" }, { output: "drew 2" }, { output: "drew 3" }])
  end

  it "keeps a refused run as its item's outcome when its failure was routed" do
    nested = child("SpecRefusedRoutedChild") { |pose| pose == 2 ? raise(refusal) : "drew #{pose}" }
    result = parent("SpecRefusedRoutedParent", nested, items: [1, 2, 3]).new(context: {}).run!

    expect(result.state).to eq(:drawn)
    expect(result.context[:frames])
      .to eq([{ output: "drew 1" }, { refused: refusal.message }, { output: "drew 3" }])
  end

  it "keeps a refused run as its item's outcome when its failure was raised" do
    nested = child("SpecRefusedRaisedChild", failure_route: false) { |pose| pose == 1 ? raise(refusal) : "ok" }
    result = parent("SpecRefusedRaisedParent", nested, items: [1, 2]).new(context: {}).run!

    expect(result.context[:frames]).to eq([{ refused: refusal.message }, { output: "ok" }])
  end

  it "fails the step on any other failure" do
    nested = child("SpecBrokenChild") { |pose| pose == 2 ? raise(Smith::WorkflowError, "pose 2 broke") : "ok" }
    result = parent("SpecBrokenParent", nested, items: [1, 2, 3]).new(context: {}).run!
    error = result.steps.find { _1.key?(:error) }[:error]

    expect(result.state).to eq(:failed)
    expect(error.message).to include("pose 2 broke")
  end

  it "runs at most `concurrency` items at once" do
    lock = Mutex.new
    running = 0
    most = 0
    nested = child("SpecCappedChild") do |pose|
      lock.synchronize { most = [most, running += 1].max }
      sleep 0.05
      lock.synchronize { running -= 1 }
      pose
    end
    result = parent("SpecCappedParent", nested, items: [1, 2, 3, 4, 5], concurrency: 2).new(context: {}).run!

    expect(result.context[:frames].map { _1[:output] }).to eq([1, 2, 3, 4, 5])
    expect(most).to eq(2)
  end

  it "runs items at once within the run's budget, each spending within its share of what is left" do
    saved = Smith.config.pricing
    Smith.config.pricing = { %w[openai gpt-5-mini] => { input_cost_per_token: 0.01, output_cost_per_token: 0.01 } }
    nested = child("SpecBudgetedChild") do |pose|
      sleep 0.05
      pose
    end
    budgeted = with_stubbed_class("SpecBudgetedParent", workflow_class) do
      initial_state :idle
      state :drawn
      state :failed
      budget total_cost: 1.0

      transition :draw, from: :idle, to: :drawn do
        workflow nested, over: ->(_context) { [1, 2, 3, 4] }, item_to: :pose, concurrency: 4, output_to: :frames
        on_failure :fail
      end
    end
    result = budgeted.new(context: {}).run!

    expect(result.state).to eq(:drawn)
    expect(result.context[:frames].map { _1[:output] }).to eq([1, 2, 3, 4])
    expect(result.total_cost).to be_within(1e-9).of(0.32)
  ensure
    Smith.config.pricing = saved
  end

  it "fails the step with a routed failure nothing may ask again for, as itself" do
    nested = child("SpecUncertainChild") { |pose| pose == 2 ? raise(Smith::RequestOutcomeUncertain, "no answer came") : "ok" }
    result = parent("SpecUncertainParent", nested, items: [1, 2]).new(context: {}).run!
    error = result.steps.find { _1.key?(:error) }[:error]

    expect(error).to be_a(Smith::RequestOutcomeUncertain)
    expect(Smith::Errors.retry_forbidden?(error)).to be(true)
  end

  it "gives each item a share of every dimension the run's budget bounds, tool calls among them" do
    tool = Class.new(Smith::Tool) { define_method(:perform) { |**_kwargs| :looked } }.new
    nested = child("SpecToolChild") do |pose|
      tool.execute
      pose
    end
    budgeted = with_stubbed_class("SpecToolParent", workflow_class) do
      initial_state :idle
      state :drawn
      state :failed
      budget tool_calls: 4

      transition :draw, from: :idle, to: :drawn do
        workflow nested, over: ->(_context) { [1, 2] }, item_to: :pose, output_to: :frames
        on_failure :fail
      end
    end
    result = budgeted.new(context: {}).run!

    expect([result.state, result.context[:frames]]).to eq([:drawn, [{ output: 1 }, { output: 2 }]])
  end

  it "runs nothing for no items" do
    ran = false
    nested = child("SpecNoItemsChild") { ran = true }
    result = parent("SpecNoItemsParent", nested, items: []).new(context: {}).run!

    expect([result.state, result.context[:frames], ran]).to eq([:drawn, [], false])
  end

  it "attributes each item's usage to its index and rolls it up" do
    nested = child("SpecUsageChild") { "kept" }
    result = parent("SpecUsageParent", nested, items: [0, 2]).new(context: {}).run!

    expect(result.context[:frames]).to eq([{ output: "kept" }, { output: "kept" }])
    expect(result.usage_entries.map(&:branch_key).sort).to eq([0, 1])
    expect(result.total_tokens).to eq(16)
  end

  it "is declared with a callable, a Symbol key and a positive concurrency" do
    nested = child("SpecDeclaredChild") { "ok" }

    expect { parent("SpecDeclaredParent", nested, items: []) }.not_to raise_error
    expect do
      with_stubbed_class("SpecBadOverParent", workflow_class) do
        initial_state :idle
        state :done
        transition(:draw, from: :idle, to: :done) { workflow nested, over: [1], item_to: :pose }
      end
    end.to raise_error(Smith::WorkflowError, /over:/)
    expect do
      with_stubbed_class("SpecBadConcurrencyParent", workflow_class) do
        initial_state :idle
        state :done
        transition(:draw, from: :idle, to: :done) do
          workflow nested, over: ->(_) { [] }, item_to: :pose, concurrency: 0
        end
      end
    end.to raise_error(Smith::WorkflowError, /concurrency:/)
  end
end
