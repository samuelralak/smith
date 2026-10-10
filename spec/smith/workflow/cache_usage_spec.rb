# frozen_string_literal: true

require "json"

RSpec.describe "Cache, thinking and response facts in usage, pricing and traces" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }

  def response_body(body) = Struct.new(:body).new(body)

  def assistant_message(**options)
    usage = { input: 10, output: 5, cache_read: 100, cache_write: 20, thinking: 2 }.merge(options)
    RubyLLM::Message.new(
      role: :assistant, content: "ok", input_tokens: usage[:input], output_tokens: usage[:output],
      cached_tokens: usage[:cache_read], cache_creation_tokens: usage[:cache_write], thinking_tokens: usage[:thinking],
      raw: response_body(usage[:body] || { "id" => "msg_01", "stop_reason" => "end_turn" })
    )
  end

  def with_pricing(catalog)
    original = Smith.config.pricing
    Smith.configure { |config| config.pricing = catalog }
    yield
  ensure
    Smith.configure { |config| config.pricing = original }
  end

  def answering_chat(message)
    chat = Object.new
    chat.define_singleton_method(:add_message) { |_message| nil }
    chat.define_singleton_method(:with_schema) { |_schema| self }
    chat.define_singleton_method(:complete) { message }
    chat
  end

  def workflow_answering_with(message, budget: nil)
    agent = with_stubbed_class("SpecCacheUsageAgent#{object_id}", agent_class) do
      register_as :spec_cache_usage_agent
      model "claude-model", provider: :anthropic, assume_model_exists: true
    end
    allow(agent).to receive(:chat) { answering_chat(message) }
    with_stubbed_class("SpecCacheUsageWorkflow#{object_id}", workflow_class) do
      initial_state :idle
      budget(**budget) if budget

      transition(:ask, from: :idle, to: :done) { execute :spec_cache_usage_agent }
    end
  end

  after { Smith::Agent::Registry.delete(:spec_cache_usage_agent) }

  describe Smith::Agent::ProviderUsage do
    it "reads cache, thinking and response facts from a provider message" do
      usage = described_class.from_message(assistant_message)

      expect(usage.to_h).to eq(
        input_tokens: 10, output_tokens: 5, cache_read_tokens: 100, cache_write_tokens: 20, thinking_tokens: 2,
        stop_reason: "end_turn", provider_message_id: "msg_01"
      )
      expect(usage.total_input_tokens).to eq(130)
      expect(usage.total_tokens).to eq(135)
    end

    it "reads the stop reason of each provider's response shape" do
      shapes = {
        { "id" => "a", "stop_reason" => "max_tokens" } => "max_tokens",
        { "id" => "b", "choices" => [{ "finish_reason" => "length" }] } => "length",
        { "id" => "c", "status" => "incomplete", "incomplete_details" => { "reason" => "max_output_tokens" } } =>
          "max_output_tokens",
        { "id" => "d", "choices" => "not a list" } => nil
      }

      shapes.each do |body, reason|
        expect(described_class.from_message(assistant_message(body:)).stop_reason).to eq(reason)
      end
    end

    it "bounds response facts and ignores counts that are not non-negative Integers" do
      message = assistant_message(cache_read: -1, cache_write: nil, thinking: nil,
                                  body: { "id" => "x" * 10_000, "stop_reason" => "end_turn" })

      usage = described_class.from_message(message)

      expect(usage.cache_read_tokens).to be_nil
      expect(usage.provider_message_id.bytesize).to be <= 256
      expect(usage.to_h.keys).to contain_exactly(:input_tokens, :output_tokens, :stop_reason, :provider_message_id)
    end

    it "sums counts across a tool loop and keeps the final response's facts" do
      first = described_class.from_message(
        assistant_message(cache_read: 50, body: { "id" => "1", "stop_reason" => "tool_use" })
      )
      last = described_class.from_message(
        assistant_message(cache_read: nil, body: { "id" => "2", "stop_reason" => "end_turn" })
      )

      sum = described_class.sum([first, last])

      expect(sum.cache_read_tokens).to eq(50)
      expect(sum.cache_write_tokens).to eq(40)
      expect([sum.stop_reason, sum.provider_message_id]).to eq(%w[end_turn 2])
    end
  end

  describe "a workflow run" do
    it "records the details on the usage entry, counts cache tokens in totals, and keeps old entries unchanged" do
      result = workflow_answering_with(assistant_message).new.run!

      entry = result.usage_entries.sole
      expect(entry.to_h).to include(
        input_tokens: 10, output_tokens: 5, cache_read_tokens: 100, cache_write_tokens: 20, thinking_tokens: 2,
        stop_reason: "end_turn", provider_message_id: "msg_01", mode: :sync
      )
      expect(entry.total_tokens).to eq(135)
      expect(result.total_tokens).to eq(135)
      restored = Smith::Workflow::UsageEntry.from_h(JSON.parse(JSON.generate(entry.to_h)))
      expect(restored).to eq(entry)

      legacy = entry.to_h.except(:cache_read_tokens, :cache_write_tokens, :thinking_tokens, :stop_reason,
                                 :provider_message_id, :mode)
      expect(Smith::Workflow::UsageEntry.from_h(legacy).to_h).to eq(legacy)
    end

    it "counts cache tokens against a token budget" do
      workflow = workflow_answering_with(assistant_message, budget: { total_tokens: 1_000 }).new
      workflow.run!

      expect(workflow.to_state[:budget_consumed]).to include(total_tokens: 135)
    end

    it "traces the details on :provider_call, :token_usage and :cost" do
      adapter = Smith::Trace::Memory.new
      original = Smith.config.trace_adapter
      Smith.configure { |config| config.trace_adapter = adapter }
      Smith::Trace.reset!

      with_pricing(%w[anthropic claude-model] => {
                     input_cost_per_token: 1.0, output_cost_per_token: 1.0,
                     cache_read_cost_per_token: 0.1, cache_write_cost_per_token: 1.25
                   }) do
        workflow_answering_with(assistant_message).new.run!
      end

      by_type = adapter.traces.group_by { _1[:type] }.transform_values { _1.last[:data] }
      expect(by_type[:provider_call]).to include(cache_read_tokens: 100, cache_write_tokens: 20, thinking_tokens: 2,
                                                 stop_reason: "end_turn", provider_message_id: "msg_01")
      expect(by_type[:token_usage]).to include(cache_read_tokens: 100, cache_write_tokens: 20)
      expect(by_type[:cost]).to include(cost: 50.0, cache_read_tokens: 100, cache_write_tokens: 20)
    ensure
      Smith.configure { |config| config.trace_adapter = original }
      Smith::Trace.reset!
    end
  end

  describe Smith::Pricing do
    let(:rates) do
      { input_cost_per_token: 1.0, output_cost_per_token: 2.0, cache_read_cost_per_token: 0.1,
        cache_write_cost_per_token: 1.25 }
    end

    def cost(**usage)
      described_class.compute_cost(model: "m", provider: "p", input_tokens: 10, output_tokens: 5, **usage)
    end

    it "prices cache reads and writes at their own rates" do
      with_pricing(%w[p m] => rates) do
        expect(cost(cache_read_tokens: 100, cache_write_tokens: 20)).to eq(10 + 10 + 10 + 25)
      end
    end

    it "prices cache tokens at 0 when the catalog has no cache rate for them" do
      with_pricing(%w[p m] => rates.except(:cache_read_cost_per_token)) do
        expect(cost(cache_read_tokens: 100, cache_write_tokens: 20)).to eq(20 + 25)
        expect(cost).to eq(20)
      end
    end

    it "chooses a tier on total input, cached and uncached" do
      tiers = { tiers: [{ max_input_tokens: 100, input_cost_per_token: 1.0, output_cost_per_token: 1.0,
                          cache_read_cost_per_token: 0.1 },
                        { max_input_tokens: nil, input_cost_per_token: 5.0, output_cost_per_token: 5.0,
                          cache_read_cost_per_token: 0.5 }] }

      with_pricing(%w[p m] => tiers) do
        expect(cost(cache_read_tokens: 50)).to eq(10 + 5 + 5.0)
        expect(cost(cache_read_tokens: 200)).to eq(50 + 25 + 100.0)
      end
    end

    it "applies a batch discount in batch mode, and the full rate without one" do
      with_pricing(%w[p m] => rates.merge(batch_discount: 0.5)) do
        expect(cost(mode: :batch)).to eq(10.0)
        expect(cost(mode: :sync)).to eq(20.0)
      end
      with_pricing(%w[p m] => rates) { expect(cost(mode: :batch)).to eq(20.0) }
    end

    it "refuses invalid cache rates and batch discounts in a catalog" do
      [{ cache_read_cost_per_token: -1 }, { cache_write_cost_per_token: "x" }, { batch_discount: 1 },
       { tiers: [{ input_cost_per_token: 1, output_cost_per_token: 1, cache_read_cost_per_token: -0.1 }] }]
        .each do |bad|
          expect { described_class.validate_catalog!(%w[p m] => rates.merge(bad)) }
            .to raise_error(Smith::PricingConfigurationError)
        end
    end
  end

  describe "composite effects" do
    let(:entry) do
      {
        "usage_id" => SecureRandom.uuid, "agent_name" => "a", "model" => "m", "provider" => "p",
        "input_tokens" => 10, "output_tokens" => 5, "cost" => nil, "attempt_kind" => "completed_attempt",
        "recorded_at" => Time.now.utc.iso8601(6)
      }
    end

    def effects(entries)
      Smith::Workflow::Composite::Effects.new(usage_entries: entries, tool_results: [], budget_consumed: {})
    end

    it "accepts entries with and without the new details, and totals cache tokens" do
      detailed = entry.merge("cache_read_tokens" => 100, "cache_write_tokens" => 20, "thinking_tokens" => 2,
                             "stop_reason" => "end_turn", "provider_message_id" => "msg_01", "mode" => "batch")

      expect(effects([entry]).total_tokens).to eq(15)
      expect(effects([detailed]).total_tokens).to eq(135)
    end

    it "rejects invalid details" do
      [{ "cache_read_tokens" => -1 }, { "stop_reason" => "" }, { "mode" => "eventually" }].each do |bad|
        expect { effects([entry.merge(bad)]) }.to raise_error(ArgumentError)
      end
    end
  end

  it "reports OpenAI Responses input with cached tokens taken out, as RubyLLM reports every provider" do
    usage = { "input_tokens" => 1_000, "output_tokens" => 10,
              "input_tokens_details" => { "cached_tokens" => 800, "cache_write_tokens" => 50 } }

    tokens = Smith::Providers::OpenAI::Responses.response_uncached_input_tokens(usage)

    expect(tokens).to eq(150)
  end
end
