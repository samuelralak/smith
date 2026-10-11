# frozen_string_literal: true

require "logger"
require "stringio"

# A host's budget ledger that records every call, a local server answering as
# Anthropic (and OpenAI), and helpers for agents and workflows that hold their
# requests on it.
RSpec.shared_context "with a recording budget ledger" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:server) { SseServer.new }
  let(:log) { StringIO.new }
  let(:ledger_class) do
    Class.new do
      attr_reader :calls

      def initialize(admit: true)
        @calls = []
        @admit = admit
        @lock = Mutex.new
      end

      def reserve!(amount, key:, expires_at:)
        @lock.synchronize { @calls << [:reserve, key, amount, expires_at] }
        @admit.respond_to?(:call) ? @admit.call(amount) : @admit
      end

      def reconcile!(key, amount) = @lock.synchronize { @calls << [:reconcile, key, amount] }
      def release!(key) = @lock.synchronize { @calls << [:release, key] }
      def kinds = @calls.map(&:first)
      def keys = @calls.map { _1[1] }
    end
  end
  let(:ledger) { ledger_class.new }
  let(:prices) { { input_cost_per_token: 0.000003, output_cost_per_token: 0.000015, batch_discount: 0.5 } }

  around do |example|
    config = RubyLLM.config
    keys = %i[anthropic_api_key anthropic_api_base openai_api_key openai_api_base max_retries]
    saved = keys.to_h { [_1, config.public_send(_1)] }
    saved_smith = %i[pricing logger batch_queue budget_hold_ttl budget_hold_output_tokens run_launcher]
                  .to_h { [_1, Smith.config.public_send(_1)] }
    example.run
  ensure
    server.close
    saved.each { |key, value| config.public_send(:"#{key}=", value) }
    saved_smith.each { |key, value| Smith.config.public_send(:"#{key}=", value) }
  end

  before do
    RubyLLM.configure do |config|
      config.anthropic_api_key = "test"
      config.anthropic_api_base = server.url
      config.openai_api_key = "test"
      config.openai_api_base = "#{server.url}/v1"
      config.max_retries = 0
    end
    Smith.config.pricing = { %w[anthropic claude-sonnet-5-5] => prices, %w[anthropic claude-haiku-5-5] => prices,
                             %w[openai gpt-5] => prices }
    Smith.config.logger = Logger.new(log)
    allow_any_instance_of(workflow_class).to receive(:sleep)
  end

  def message(text, id: "msg_1", tokens: [100, 20], content: nil, stop: "end_turn")
    { "id" => id, "type" => "message", "role" => "assistant", "model" => "claude-sonnet-5-5",
      "content" => content || [{ "type" => "text", "text" => text }], "stop_reason" => stop,
      "usage" => { "input_tokens" => tokens.first, "output_tokens" => tokens.last } }
  end

  def tool_use(name, id: "toolu_1", input: { "query" => "x" })
    [{ "type" => "tool_use", "id" => id, "name" => name, "input" => input }]
  end

  def agent(name, register: :spec_ledger_agent, model: "claude-sonnet-5-5", provider: :anthropic, &body)
    Smith::Agent::Registry.delete(register)
    klass = with_stubbed_class(name, agent_class) do
      register_as register
      model model, provider:, assume_model_exists: true
      params max_tokens: 500
    end
    klass.class_exec(&body) if body
    klass
  end

  def asking(name, agent: :spec_ledger_agent, mode: nil, scope: [], **step, &ledger_block)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      budget_ledger(*scope, &ledger_block) if ledger_block
      seed_messages { |_context| [{ role: :user, content: "classify this posting" }] }
      transition :ask, from: :idle, to: :done do
        execute agent, output_to: :answer, **({ mode: } if mode).to_h, **step
        on_failure :fail
      end
    end
  end

  def batch_queue
    Class.new do
      attr_reader :items

      def initialize = @items = []
      def enqueue(**request) = @items << request
    end.new
  end

  def amount(input, output, cost) = Smith::Budget::Amount.new(input_tokens: input, output_tokens: output, cost:)
end
