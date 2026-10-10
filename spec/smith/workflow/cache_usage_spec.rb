# frozen_string_literal: true

require "json"

RSpec.describe "Cache, thinking and response facts in usage, pricing and traces" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }

  def response_body(body) = Struct.new(:body).new(body)

  def anthropic_body(id, stop_reason) = { "type" => "message", "id" => id, "stop_reason" => stop_reason }

  def assistant_message(**options)
    usage = { input: 10, output: 5, cache_read: 100, cache_write: 20, thinking: 2 }.merge(options)
    RubyLLM::Message.new(
      role: :assistant, content: "ok", input_tokens: usage[:input], output_tokens: usage[:output],
      cached_tokens: usage[:cache_read], cache_creation_tokens: usage[:cache_write], thinking_tokens: usage[:thinking],
      raw: response_body(usage[:body] || anthropic_body("msg_01", "end_turn"))
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

    it "reads the stop reason and message id of each provider's body, recognized by its own marker" do
      shapes = {
        anthropic_body("a", "max_tokens") => %w[max_tokens a],
        { "object" => "chat.completion", "id" => "b", "choices" => [{ "finish_reason" => "length" }] } => %w[length b],
        { "object" => "response", "id" => "c", "status" => "incomplete",
          "incomplete_details" => { "reason" => "max_output_tokens" } } => %w[max_output_tokens c],
        { "object" => "response", "id" => "d", "status" => "completed", "incomplete_details" => nil } =>
          %w[completed d],
        { "candidates" => [{ "finishReason" => "MAX_TOKENS" }], "responseId" => "e" } => %w[MAX_TOKENS e],
        { "output" => {}, "stopReason" => "end_turn" } => ["end_turn", nil],
        { "object" => "chat.completion", "id" => "g", "choices" => "not a list" } => [nil, "g"],
        { "id" => "h", "status" => "user text that only looks like a status" } => [nil, nil],
        { "id" => "i", "stop_reason" => "end_turn" } => [nil, nil],
        { "id" => "j", "choices" => [{ "finish_reason" => "stop" }] } => [nil, nil]
      }

      shapes.each do |body, facts|
        usage = described_class.from_message(assistant_message(body:))
        expect([usage.stop_reason, usage.provider_message_id]).to eq(facts), body.inspect
      end
    end

    it "reads cache counts under either RubyLLM name and ignores counts that are not Integers" do
      message = Struct.new(:input_tokens, :output_tokens, :cached_tokens, :cache_creation_tokens, :thinking_tokens)

      usage = described_class.from_message(message.new(10, 5, 7, 3, 1.5))
      odd = described_class.from_message(message.new(10, 5, 2.0, "3", nil))

      expect(usage.to_h).to eq(input_tokens: 10, output_tokens: 5, cache_read_tokens: 7, cache_write_tokens: 3)
      expect(odd.to_h).to eq(input_tokens: 10, output_tokens: 5)
      expect(described_class.sum([odd, odd]).to_h).to eq(input_tokens: 20, output_tokens: 10)
    end

    it "bounds response facts and ignores counts that are not non-negative Integers" do
      message = assistant_message(cache_read: -1, cache_write: nil, thinking: nil,
                                  body: anthropic_body("x" * 10_000, "end_turn"))

      usage = described_class.from_message(message)

      expect(usage.cache_read_tokens).to be_nil
      expect(usage.provider_message_id.bytesize).to be <= 256
      expect(usage.to_h.keys).to contain_exactly(:input_tokens, :output_tokens, :stop_reason, :provider_message_id)
    end

    it "sums counts across a tool loop and keeps the final response's facts" do
      first = described_class.from_message(
        assistant_message(cache_read: 50, body: anthropic_body("1", "tool_use"))
      )
      last = described_class.from_message(
        assistant_message(cache_read: nil, body: anthropic_body("2", "end_turn"))
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
        stop_reason: "end_turn", provider_message_id: "msg_01"
      )
      expect(entry.to_h).not_to have_key(:mode)
      expect(entry.total_tokens).to eq(135)
      expect(result.total_tokens).to eq(135)
      restored = Smith::Workflow::UsageEntry.from_h(JSON.parse(JSON.generate(entry.to_h)))
      expect(restored).to eq(entry)

      legacy_json = JSON.generate(
        entry.to_h.except(:cache_read_tokens, :cache_write_tokens, :thinking_tokens, :stop_reason, :provider_message_id)
      )
      expect(JSON.generate(Smith::Workflow::UsageEntry.from_h(JSON.parse(legacy_json)).to_h)).to eq(legacy_json)
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
      expect(by_type[:cost]).not_to have_key(:cache_unpriced)
    ensure
      Smith.configure { |config| config.trace_adapter = original }
      Smith::Trace.reset!
    end

    it "marks a :cost trace whose cache tokens were priced at 0 for lack of a rate" do
      adapter = Smith::Trace::Memory.new
      original = Smith.config.trace_adapter
      Smith.configure { |config| config.trace_adapter = adapter }
      Smith::Trace.reset!

      with_pricing(%w[anthropic claude-model] => { input_cost_per_token: 1.0, output_cost_per_token: 1.0 }) do
        workflow_answering_with(assistant_message).new.run!
      end

      expect(adapter.traces.find { _1[:type] == :cost }[:data]).to include(cost: 15.0, cache_unpriced: true)
    ensure
      Smith.configure { |config| config.trace_adapter = original }
      Smith::Trace.reset!
    end
  end

  describe "accounting beyond the completed response" do
    def message(input:, output:, cache_read: nil, body: anthropic_body("m", "end_turn"))
      RubyLLM::Message.new(role: :assistant, content: "ok", input_tokens: input, output_tokens: output,
                           cached_tokens: cache_read, raw: body && response_body(body))
    end

    def recording_chat(&complete)
      chat = Object.new
      messages = []
      chat.define_singleton_method(:messages) { messages }
      chat.define_singleton_method(:add_message) { |added| messages << added }
      chat.define_singleton_method(:with_schema) { |_schema| self }
      chat.define_singleton_method(:complete) { complete.call(messages) }
      chat
    end

    def fallback_agent(name, &chat_for_model)
      agent = with_stubbed_class("Spec#{name}Agent", agent_class) do
        register_as :spec_cache_usage_agent
        model "primary", provider: :anthropic, assume_model_exists: true
        fallback_models model: "backup", provider: :anthropic
      end
      allow(agent).to receive(:chat) do |**options|
        recording_chat { |messages| chat_for_model.call(options[:model], messages) }
      end
    end

    def fallback_workflow(name, budget:, &chat_for_model)
      fallback_agent(name, &chat_for_model)
      with_stubbed_class("Spec#{name}Workflow", workflow_class) do
        initial_state :idle
        state :failed
        budget(**budget)

        transition(:ask, from: :idle, to: :done) do
          execute :spec_cache_usage_agent
          on_failure :fail
        end
      end
    end

    let(:budget) { { total_tokens: 100_000, total_cost: 100_000.0 } }

    let(:catalog) do
      { %w[anthropic primary] => { input_cost_per_token: 1.0, output_cost_per_token: 1.0,
                                   cache_read_cost_per_token: 0.5 },
        %w[anthropic backup] => { input_cost_per_token: 1.0, output_cost_per_token: 1.0 },
        %w[anthropic claude-model] => { input_cost_per_token: 1.0, output_cost_per_token: 1.0,
                                        cache_read_cost_per_token: 0.5 } }
    end

    it "settles a completed tool-loop round before a failed attempt into the budget, cache tokens included" do
      klass = fallback_workflow("PrefixSettled", budget:) do |model, messages|
        next message(input: 1, output: 1) unless model == "primary"

        messages << message(input: 10, output: 5, cache_read: 1_000)
        raise RubyLLM::ServerError, "overloaded"
      end
      workflow = klass.new

      result = with_pricing(catalog) { workflow.run! }

      expect(result.total_tokens).to eq(1_017)
      expect(result.total_cost).to eq(517.0)
      expect(workflow.to_state[:budget_consumed]).to eq(total_tokens: 1_017, total_cost: 517.0)
    end

    it "records a failed attempt's cache tokens in its entry, cost, totals and budget, as its trace does" do
      billed = Class.new(RubyLLM::ServerError) do
        def input_tokens = 10
        def output_tokens = 5
        def cached_tokens = 1_000
      end
      klass = fallback_workflow("FailedCache", budget:) do |model, _|
        raise billed, "overloaded" if model == "primary"

        message(input: 1, output: 1)
      end
      workflow = klass.new

      result = with_pricing(catalog) { workflow.run! }

      failed = result.usage_entries.find { _1.attempt_kind == :failed_attempt }
      expect(failed.to_h).to include(input_tokens: 10, output_tokens: 5, cache_read_tokens: 1_000, cost: 515.0)
      expect(result.total_tokens).to eq(1_017)
      expect(workflow.to_state[:budget_consumed]).to eq(total_tokens: 1_017, total_cost: 517.0)
    end

    it "settles a partially metered tool loop's metered tokens and takes facts from its last response" do
      adapter = Smith::Trace::Memory.new
      original = Smith.config.trace_adapter
      Smith.configure { |config| config.trace_adapter = adapter }
      Smith::Trace.reset!
      first = message(input: 10, output: 5, cache_read: 100,
                      body: { "type" => "message", "id" => "a", "stop_reason" => "tool_use" })
      last = RubyLLM::Message.new(role: :assistant, content: "done",
                                  raw: response_body({ "type" => "message", "id" => "b", "stop_reason" => "end_turn" }))
      agent = with_stubbed_class("SpecPartialMeterAgent", agent_class) do
        register_as :spec_cache_usage_agent
        model "claude-model", provider: :anthropic, assume_model_exists: true
      end
      allow(agent).to receive(:chat) { recording_chat { |messages| messages.push(first, last) && last } }
      workflow = with_stubbed_class("SpecPartialMeterWorkflow", workflow_class) do
        initial_state :idle
        budget total_tokens: 100_000, total_cost: 100_000.0
        transition(:ask, from: :idle, to: :done) { execute :spec_cache_usage_agent }
      end.new

      result = with_pricing(catalog) { workflow.run! }

      expect(result.total_tokens).to eq(115)
      expect(workflow.to_state[:budget_consumed]).to eq(total_tokens: 115, total_cost: 65.0)
      provider_call = adapter.traces.find { _1[:type] == :provider_call }[:data]
      expect(provider_call).to include(stop_reason: "end_turn", provider_message_id: "b")
    ensure
      Smith.configure { |config| config.trace_adapter = original }
      Smith::Trace.reset!
    end

    it "keeps a billed call when its raw body cannot be read" do
      odd = Class.new(Hash) { def [](_key) = raise(NoMethodError, "unreadable") }.new
      raising = Object.new
      raising.define_singleton_method(:body) { raise "unreadable" }
      [odd, Hash.new { raise KeyError, "unreadable" }.merge("type" => "message"), raising].each do |raw|
        message = RubyLLM::Message.new(role: :assistant, content: "ok", input_tokens: 50, output_tokens: 5, raw:)

        result = workflow_answering_with(message).new.run!

        expect(result.state).to eq(:done)
        expect(result.total_tokens).to eq(55)
        Smith::Agent::Registry.delete(:spec_cache_usage_agent)
      end
    end

    it "counts the known parts of a result whose usage is half known" do
      result = Smith::Workflow::AgentResult.new(input_tokens: 500, output_tokens: nil, cache_read_tokens: 20)

      expect(result.billable_tokens).to eq(520)
      expect(Smith::Workflow::AgentResult.new.billable_tokens).to eq(0)
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

    it "lets a tier without cache rates use the entry's, and chooses the tier on cache writes too" do
      tiered = { cache_read_cost_per_token: 0.5, cache_write_cost_per_token: 2.0,
                 tiers: [{ max_input_tokens: 100, input_cost_per_token: 1.0, output_cost_per_token: 1.0 },
                         { max_input_tokens: nil, input_cost_per_token: 5.0, output_cost_per_token: 5.0,
                           cache_read_cost_per_token: 1.0 }] }

      with_pricing(%w[p m] => tiered) do
        expect(cost(cache_read_tokens: 50)).to eq(10 + 5 + 25.0)
        expect(cost(cache_write_tokens: 90)).to eq(10 + 5 + 180.0)
        expect(cost(cache_write_tokens: 91)).to eq(50 + 25 + 182.0)
        expect(cost(cache_read_tokens: 200)).to eq(50 + 25 + 200.0)
      end
      tier_without_input = { input_cost_per_token: 1.0, tiers: [{ max_input_tokens: nil, output_cost_per_token: 1.0 }] }
      with_pricing(%w[p m] => tier_without_input) { expect(cost).to be_nil }
      with_pricing(%w[p m] => 5) { expect(cost).to be_nil }
    end

    it "reads String-keyed rates and prices counts that are not non-negative Integers as 0" do
      with_pricing(%w[p m] => { "input_cost_per_token" => 1.0, "output_cost_per_token" => 2.0,
                                "cache_read_cost_per_token" => 0.1 }) do
        expect(cost(cache_read_tokens: 100)).to eq(10 + 10 + 10.0)
        expect(cost(cache_read_tokens: -5, cache_write_tokens: nil)).to eq(20.0)
        expect(described_class.compute_cost(model: "m", provider: "p", input_tokens: nil, output_tokens: 1.5))
          .to eq(0.0)
      end
    end

    it "says when cache tokens were priced at 0 for lack of a rate" do
      unpriced = lambda do |**counts|
        described_class.cache_unpriced?(model: "m", provider: "p", input_tokens: 10, **counts)
      end

      with_pricing(%w[p m] => rates.except(:cache_write_cost_per_token)) do
        expect(unpriced.call(cache_write_tokens: 5)).to be(true)
        expect(unpriced.call(cache_read_tokens: 5)).to be(false)
      end
      with_pricing(%w[p m] => rates.except(:cache_read_cost_per_token)) do
        expect(unpriced.call(cache_read_tokens: 5)).to be(true)
        expect(unpriced.call(cache_write_tokens: 5)).to be(false)
        expect(unpriced.call).to be(false)
        expect(described_class.cache_unpriced?(model: "x", provider: "p", input_tokens: 1, cache_write_tokens: 5))
          .to be(false)
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
       { tiers: [{ input_cost_per_token: 1, output_cost_per_token: 1, cache_read_cost_per_token: -0.1 }] },
       { cache_read_cost_per_token: Complex(1, 1) }, { cache_read_cost_per_token: Rational(1, 2) },
       { batch_discount: -0.1 }, { batch_discount: Complex(0, 1) }, { cache_read_cost_per_token: false },
       { tiers: [{ input_cost_per_token: 1, output_cost_per_token: 1, batch_discount: 0.5 }] }]
        .each do |bad|
          expect { described_class.validate_catalog!(%w[p m] => rates.merge(bad)) }
            .to raise_error(Smith::PricingConfigurationError)
        end
      [rates.except(:cache_write_cost_per_token).merge("cache_write_cost_per_token" => -2),
       rates.merge("cache_write_cost_per_token" => -2)].each do |bad|
        expect { described_class.validate_catalog!(%w[p m] => bad) }.to raise_error(Smith::PricingConfigurationError)
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
      [{ "cache_read_tokens" => -1 }, { "cache_write_tokens" => 1.5 }, { "stop_reason" => "" },
       { "stop_reason" => "\u00e9" * 129 }, { "mode" => "eventually" }].each do |bad|
        expect { effects([entry.merge(bad)]) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "the OpenAI Responses adapter" do
    def parsed_usage(usage)
      body = { "object" => "response", "id" => "resp_1", "status" => "completed", "model" => "gpt-x",
               "output" => [{ "type" => "message", "role" => "assistant",
                              "content" => [{ "type" => "output_text", "text" => "hi" }] }],
               "usage" => usage }
      message = Smith::Providers::OpenAI::Responses.parse_response_response(response_body(body))
      Smith::Agent::ProviderUsage.from_message(message)
    end

    it "reports input with cached and cache-written input taken out, keeping the provider's total" do
      usage = parsed_usage("input_tokens" => 1_000, "output_tokens" => 10,
                           "input_tokens_details" => { "cached_tokens" => 800, "cache_write_tokens" => 50 })

      expect(usage.to_h).to include(input_tokens: 150, cache_read_tokens: 800, cache_write_tokens: 50,
                                    stop_reason: "completed", provider_message_id: "resp_1")
      expect(usage.total_tokens).to eq(1_010)
    end

    it "caps cache counts at the reported input and ignores counts that are not Integers" do
      over = parsed_usage("input_tokens" => 100, "output_tokens" => 10,
                          "input_tokens_details" => { "cached_tokens" => 800, "cache_write_tokens" => 50 })
      odd = parsed_usage("input_tokens" => 1_000, "output_tokens" => 10,
                         "input_tokens_details" => { "cached_tokens" => "800" })

      expect(over.to_h).to include(input_tokens: 0, cache_read_tokens: 100, cache_write_tokens: 0)
      expect(over.total_tokens).to eq(110)
      expect(odd.to_h).to include(input_tokens: 1_000)
      expect(odd.to_h).not_to have_key(:cache_read_tokens)
      expect(odd.total_tokens).to eq(1_010)
    end
  end
end
