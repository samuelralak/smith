# frozen_string_literal: true

require "json"

# An agent's automatic prompt cache: Anthropic is asked to cache each
# request's longest prefix with a top-level cache_control, which counts as
# one of a request's four breakpoints; any other provider is asked nothing.
RSpec.describe "Smith agent prompt_cache" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:chats) { [] }

  after { Smith::Agent::Registry.delete(:spec_cache_agent) }

  def fake_chat(params)
    recorded = chats
    lambda do |**_options|
      chat = { messages: [], params: params.dup }
      recorded << chat
      double_chat(chat)
    end
  end

  def double_chat(chat)
    object = Object.new
    object.define_singleton_method(:add_message) { |message| chat[:messages] << message }
    object.define_singleton_method(:with_schema) { |_schema| self }
    object.define_singleton_method(:params) { chat[:params] }
    object.define_singleton_method(:with_params) { |**params| chat[:params] = params and self }
    object.define_singleton_method(:complete) { Struct.new(:content, :input_tokens, :output_tokens).new("ok", 1, 1) }
    object
  end

  def agent(name, provider: :anthropic, model: "claude-opus-5-5", chat_params: {}, &body)
    Smith::Agent::Registry.delete(:spec_cache_agent)
    klass = with_stubbed_class(name, agent_class) do
      register_as :spec_cache_agent
      model model, provider:
    end
    klass.class_exec(&body) if body
    allow(klass).to receive(:chat, &fake_chat(chat_params))
    klass
  end

  def run(name, input: nil)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      transition :ask, from: :idle, to: :done do
        input ? execute(:spec_cache_agent, input: ->(_context) { input }) : execute(:spec_cache_agent)
        on_failure :fail
      end
    end.new(context: {}).run!
  end

  it "asks Anthropic for its automatic cache when the agent does, and no other provider" do
    agent("SpecCacheAnthropic") { prompt_cache :automatic }
    run("SpecCacheAnthropicFlow")
    agent("SpecCacheOpenAI", provider: :openai, model: "gpt-5-mini") { prompt_cache :automatic }
    run("SpecCacheOpenAIFlow")
    agent("SpecCacheNone")
    run("SpecCacheNoneFlow")

    expect(chats.map { _1[:params][:cache_control] }).to eq([{ type: "ephemeral" }, nil, nil])
  end

  it "is :none unless asked, passes to a subclass and refuses any other mode" do
    parent = agent("SpecCacheParent") { prompt_cache :automatic }

    expect([agent_class.prompt_cache, Class.new(parent).prompt_cache]).to eq(%i[none automatic])
    expect { parent.prompt_cache(:always) }.to raise_error(ArgumentError, "prompt_cache must be :none or :automatic")
  end

  it "reaches Anthropic as the request's top-level cache_control" do
    server = SseServer.new
    saved = %i[anthropic_api_key anthropic_api_base max_retries].to_h { [_1, RubyLLM.config.public_send(_1)] }
    RubyLLM.configure do |config|
      config.anthropic_api_key = "test"
      config.anthropic_api_base = server.url
      config.max_retries = 0
    end
    server.reply(json: { "id" => "msg_1", "type" => "message", "role" => "assistant", "model" => "claude-opus-5-5",
                         "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn",
                         "usage" => { "input_tokens" => 5, "output_tokens" => 1 } })
    Smith::Agent::Registry.delete(:spec_cache_agent)
    with_stubbed_class("SpecCacheWire", agent_class) do
      register_as :spec_cache_agent
      model "claude-opus-5-5", provider: :anthropic, assume_model_exists: true
      prompt_cache :automatic
    end

    run("SpecCacheWireFlow", input: [{ role: :user, content: "hello" }])

    body = server.requests.sole.body
    expect((body.is_a?(String) ? JSON.parse(body) : body)["cache_control"]).to eq("type" => "ephemeral")
  ensure
    server&.close
    saved&.each { |key, value| RubyLLM.config.public_send(:"#{key}=", value) }
  end

  it "counts the automatic cache among a request's four breakpoints: three marked parts are sent, four are not" do
    agent("SpecCacheBreakpoints") { prompt_cache :automatic }
    parts = ->(count) { [Smith::Message.user(Array.new(count) { |index| Smith::Content.text("part #{index}", cache: true) })] }

    refused = run("SpecCacheBreakpointsFlow", input: parts.call(4))
    sent = run("SpecCacheBoundaryFlow", input: parts.call(3))

    expect([refused.state, refused.last_error.message]).to eq(
      [:failed, "5 cache breakpoints are asked for, an automatic prompt cache counting one; Anthropic takes at " \
                "most 4 in one request"]
    )
    expect([sent.state, chats.length]).to eq([:done, 1])
  end

  it "counts a top-level cache_control the chat's params already carry" do
    agent("SpecCacheParams", chat_params: { cache_control: { type: "ephemeral" } })
    parts = [Smith::Message.user(Array.new(4) { |index| Smith::Content.text("part #{index}", cache: true) })]

    result = run("SpecCacheParamsFlow", input: parts)

    expect(result.last_error.message).to start_with("5 cache breakpoints are asked for, an automatic prompt cache")
  end

  it "leaves a batch request without it, one turn read once" do
    queue = Class.new do
      attr_reader :items

      def initialize = @items = []
      def enqueue(**request) = @items << request
    end.new
    saved = Smith.config.batch_queue
    saved_key = RubyLLM.config.anthropic_api_key
    Smith.config.batch_queue = queue
    RubyLLM.config.anthropic_api_key = "test"
    Smith::Agent::Registry.delete(:spec_cache_agent)
    with_stubbed_class("SpecCacheBatch", agent_class) do
      register_as :spec_cache_agent
      model "claude-opus-5-5", provider: :anthropic, assume_model_exists: true
      prompt_cache :automatic
    end
    flow = with_stubbed_class("SpecCacheBatchFlow", workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: "hello" }] }
      transition :ask, from: :idle, to: :done do
        execute :spec_cache_agent, mode: :batch
        on_failure :fail
      end
    end

    flow.new(context: {}).run_persisted!("cache-batch", adapter: Smith::PersistenceAdapters::Memory.new)

    expect(queue.items.sole[:request]["params"]).not_to have_key("cache_control")
  ensure
    Smith.config.batch_queue = saved
    RubyLLM.config.anthropic_api_key = saved_key
  end
end
