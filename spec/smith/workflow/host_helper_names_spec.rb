# frozen_string_literal: true

require "base64"

# 0.16.0 gave Smith::Workflow 27 private helpers for image agents and fan-outs
# over items, so a host workflow with a method of one of those names replaced
# Smith's own. Smith keeps them off Smith::Workflow: a host's method of the
# same name is the host's alone, and the features they served run as before.
RSpec.describe "A host workflow with methods named as 0.16.0's helpers" do
  include_context "with a recording budget ledger"

  let(:names) do
    %w[check_image_agent! ended_refused execute_nested_items failed_paint goes_again? held_paint image_refusals
       item_envelope item_shares items_environment kept moderation_blocked? nested_item_outcome nested_items_of
       outcome_uncertain paint_model painted painted_completion painting_attempt painting_chat refused_completion
       run_item_child run_nested_item run_nested_item_child settle_item_envelope step_may_retry? throttled?]
  end
  # Every call Smith makes to one of the host's methods.
  let(:called) { [] }
  let(:drawn) { "\x89PNG\r\n\x1A\n".b + "drawn".b }
  let(:usage) do
    { "input_tokens" => 400, "input_tokens_details" => { "image_tokens" => 323, "text_tokens" => 77 },
      "output_tokens" => 823, "output_tokens_details" => { "image_tokens" => 823, "text_tokens" => 0 } }
  end
  let(:painted) { { "created" => 1, "data" => [{ "b64_json" => Base64.strict_encode64(drawn) }], "usage" => usage } }
  let(:blocked) { { "error" => { "code" => "moderation_blocked", "message" => "Rejected by the safety system." } } }

  around do |example|
    saved = RubyLLM.config.retry_interval
    example.run
  ensure
    RubyLLM.config.retry_interval = saved
  end

  before do
    image_prices = { input_cost_per_token: 0.000005, output_cost_per_token: 0.00003,
                     image_output_tokens: { "1024x1024" => { "low" => 823 } } }
    Smith.config.pricing = Smith.config.pricing.merge(%w[openai gpt-image-test] => image_prices,
                                                      %w[openai gpt-image-other] => image_prices,
                                                      %w[openai gpt-5-mini] => prices)
    RubyLLM.config.retry_interval = 0
  end

  # A host workflow class defining each name, recording any call.
  def host_workflow(name, &body)
    names = self.names
    called = self.called
    with_stubbed_class(name, workflow_class) do
      names.each do |helper|
        define_method(helper) do |*_args, **_kwargs, &_block|
          called << helper
          raise "the host's own #{helper}"
        end
        private helper
      end
      class_exec(&body)
    end
  end

  def image_agent(name, &body)
    Smith::Agent::Registry.delete(:spec_host_painter)
    klass = with_stubbed_class(name, agent_class) do
      register_as :spec_host_painter
      model "gpt-image-test", provider: :openai, assume_model_exists: true
      image size: "1024x1024", quality: "low"
      instructions "Draw it."
    end
    klass.class_exec(&body) if body
    klass
  end

  def drawing(name, **step)
    built = ledger
    host_workflow(name) do
      initial_state :idle
      state :done
      state :failed
      budget_ledger { |_scope| built }
      transition :draw, from: :idle, to: :done do
        execute :spec_host_painter, input: ->(_context) { [{ role: :user, content: "A fox." }] }, output_to: :drawn,
                                    **step
        on_failure :fail
      end
    end
  end

  def failure(result) = result.steps.find { _1.key?(:error) }&.fetch(:error)

  it "finds none of the names on Smith::Workflow, nor the two constants 0.16.0 added to it" do
    expect(names.length).to eq(27)
    expect(names.select { Smith::Workflow.private_method_defined?(_1) || Smith::Workflow.method_defined?(_1) })
      .to eq([])
    expect(Smith::Workflow.constants & %i[MODERATION_BLOCKED NestedItemsExecution]).to eq([])
  end

  it "paints an image agent's answer, its throttle going to the fallback" do
    image_agent("SpecHostPainter") { fallback_models "openai/gpt-image-other" }
    server.reply(json: { "error" => { "message" => "Slow down" } }, status: "429 Too Many Requests")
    server.reply(json: painted)
    result = drawing("SpecHostDrawing").new(context: {}).run!

    expect([result.state, called]).to eq([:done, []])
    expect(result.context[:drawn]).to include(type: "image", media_type: "image/png")
    expect(server.requests.map(&:path)).to eq(%w[/v1/images/generations] * 2)
    expect(ledger.kinds).to eq(%i[reserve release reserve reconcile])
  end

  it "takes a moderation block as a refusal, and an answer with no image as an output failure with its usage" do
    image_agent("SpecHostBlocked")
    server.reply(json: blocked, status: "400 Bad Request")
    refused = drawing("SpecHostBlockedDrawing").new(context: {}).run!
    image_agent("SpecHostUnkept")
    server.reply(json: painted.merge("data" => [{ "url" => nil }]))
    unkept = drawing("SpecHostUnkeptDrawing").new(context: {}).run!

    expect(failure(refused)).to be_a(Smith::OutputRefused)
    expect(failure(refused).stop_reason).to eq("moderation_blocked")
    expect(failure(unkept)).to be_a(Smith::OutputInvalid)
    expect(unkept.usage_entries.sole.to_h).to include(output_tokens: 823, attempt_kind: :partial_attempt)
    expect(called).to eq([])
  end

  it "never sends again a request a server failed or whose answer never came, and refuses an image agent's tools" do
    RubyLLM.config.max_retries = 3
    image_agent("SpecHostServerError") { fallback_models "openai/gpt-image-other" }
    server.reply(json: { "error" => { "message" => "Internal" } }, status: "500 Internal Server Error")
    failed = drawing("SpecHostServerDrawing").new(context: {}).run!
    image_agent("SpecHostDropped")
    server.reply(drop: true)
    dropped = drawing("SpecHostDroppedDrawing").new(context: {}).run!
    tool = Class.new(Smith::Tool) do
      def self.name = "SpecHostLookup"
      description "looks"
      def execute = "x"
    end
    image_agent("SpecHostTools") { tools tool }
    tooled = drawing("SpecHostToolsDrawing").new(context: {}).run!

    expect(failure(failed)).to be_a(Smith::ProviderPermanentFailure)
    expect(failure(dropped)).to be_a(Smith::RequestOutcomeUncertain)
    expect(failure(tooled).message).to include("answers with an image, which takes no tools")
    expect([server.requests.size, called]).to eq([2, []])
  end

  it "refuses an image agent in a streamed step and in a batch step" do
    sink = Class.new { %i[start delta reset finish fail withdraw suspend].each { define_method(_1) { |*| nil } } }
    allow(Smith.config).to receive(:stream_sinks).and_return(reply: ->(_info) { sink.new })
    Smith.config.batch_queue = queue = batch_queue
    image_agent("SpecHostStepModes")
    streamed = drawing("SpecHostStreamedDrawing", stream: :reply).new(context: {}).run!
    batched = drawing("SpecHostBatchedDrawing", mode: :batch).new(context: {}).run!

    expect(failure(streamed).message).to end_with("which takes no a streamed step")
    expect(failure(batched).message).to end_with("which takes no a batch")
    expect([server.requests, queue.items, called]).to eq([[], [], []])
  end

  context "with a fan-out over items" do
    def drawer(&work)
      Smith::Agent::Registry.delete(:spec_host_items_drawer)
      klass = with_stubbed_class("SpecHostItemsDrawer", agent_class) do
        register_as :spec_host_items_drawer
        model "gpt-5-mini", provider: :openai, assume_model_exists: true
      end
      allow(klass).to receive(:chat) { answering_chat(work) }
    end

    # A chat answering what `work` makes of the item its request names.
    def answering_chat(work)
      asked = []
      Object.new.tap do |chat|
        chat.define_singleton_method(:add_message) { |message| asked << message }
        chat.define_singleton_method(:complete) do
          answer = work.call(JSON.parse(asked.last[:content].to_s))
          Struct.new(:content, :input_tokens, :output_tokens).new(answer, 5, 3)
        end
      end
    end

    def items_child(name, &work)
      drawer(&work)
      host_workflow(name) do
        initial_state :idle
        state :done
        state :failed
        transition :work, from: :idle, to: :done do
          execute :spec_host_items_drawer,
                  input: ->(context) { [{ role: :user, content: JSON.generate(context[:pose]) }] }
          on_failure :fail
        end
      end
    end

    def items_parent(name, nested, items)
      host_workflow(name) do
        initial_state :idle
        state :drawn
        state :failed
        budget total_cost: 1.0, tool_calls: 8
        transition :draw, from: :idle, to: :drawn do
          workflow nested, over: ->(_context) { items }, item_to: :pose, concurrency: 2, output_to: :frames
          on_failure :fail
        end
      end
    end

    it "runs one nested run an item within its share of the budget, a refused run its item's outcome" do
      refusal = Smith::OutputRefused.new(agent_name: :spec_host_items_drawer, model_used: "m",
                                         stop_reason: "moderation_blocked")
      nested = items_child("SpecHostItemsChild") { |pose| pose == 2 ? raise(refusal) : "drew #{pose}" }
      result = items_parent("SpecHostItemsParent", nested, [1, 2, 3]).new(context: {}).run!

      expect(result.state).to eq(:drawn)
      expect(result.context[:frames]).to eq([{ output: "drew 1" }, { refused: refusal.message }, { output: "drew 3" }])
      expect(result.usage_entries.map(&:branch_key).sort).to eq([0, 2])
      expect(result.total_tokens).to eq(16)
      expect(called).to eq([])
    end

    it "runs nothing for no items" do
      nested = items_child("SpecHostNoItemsChild") { "ran" }
      result = items_parent("SpecHostNoItemsParent", nested, []).new(context: {}).run!

      expect([result.state, result.context[:frames], called]).to eq([:drawn, [], []])
    end
  end
end
