# frozen_string_literal: true

# Prompt-cache markers say how a request is billed, never what it asks, so
# what identifies a request leaves them out (Smith::CacheMarkers).
RSpec.describe "Smith prompt cache markers" do
  include_context "with a recording budget ledger"

  let(:marker) { { type: "ephemeral" } }

  it "leaves markers out where Anthropic puts them: the request, its system and message blocks, tool results, tools" do
    request = {
      "cache_control" => { "type" => "ephemeral" },
      "system" => [{ "type" => "text", "text" => "Be brief.",
                     "cache_control" => { "type" => "ephemeral", "ttl" => "1h" } }],
      messages: [{ role: "user", content: [{ type: "text", text: "Hi", cache_control: marker },
                                           { type: "tool_result", tool_use_id: "t1",
                                             content: [{ type: "text", text: "found", cache_control: marker }] }] }],
      tools: [{ name: "find", cache_control: marker,
                input_schema: { type: "object", properties: { cache_control: { type: "string" } } } }]
    }

    expect(Smith::CacheMarkers.strip_request(request)).to eq(
      "system" => [{ "type" => "text", "text" => "Be brief." }],
      messages: [{ role: "user", content: [{ type: "text", text: "Hi" },
                                           { type: "tool_result", tool_use_id: "t1",
                                             content: [{ type: "text", text: "found" }] }] }],
      tools: [{ name: "find", input_schema: { type: "object", properties: { cache_control: { type: "string" } } } }]
    )
  end

  it "never touches what a request carries as data, however marker-shaped or deep it is" do
    deep = (1..5_000).reduce({ "leaf" => true }) { |inner, _| { "next" => inner } }
    blocks = [{ type: "tool_use", id: "t1", name: "find", input: { cache_control: marker, deep: } }]
    schema_default = { tools: [{ name: "find", input_schema: { type: "object", default: { cache_control: marker } } }] }

    expect(Smith::CacheMarkers.strip_blocks(blocks)).to eq(blocks)
    expect(Smith::CacheMarkers.strip_request(schema_default)).to eq(schema_default)
  end

  describe "the response memo" do
    let(:memo_class) do
      Class.new do
        attr_reader :records
        attr_accessor :crash

        def initialize = @records = {}
        def fetch(key) = @records[key]

        def store(key, record)
          @records[key] = record
          raise crash if crash && record["complete"]
        end
      end
    end
    let(:memo) { memo_class.new }
    let(:crash) { Class.new(Exception) } # rubocop:disable Lint/InheritException
    let(:adapter) { Smith::PersistenceAdapters::Memory.new }

    around do |example|
      saved = Smith.config.response_memo
      Smith.config.response_memo = memo
      example.run
    ensure
      Smith.config.response_memo = saved
    end

    def caching_agent(name, cached)
      agent(name) do
        instructions do
          RubyLLM::Providers::Anthropic::Content.new("Be brief.", cache: cached.call)
        end
      end
    end

    it "gives a replay the kept answer though it caches its instructions where the first call did not" do
      cached = false
      caching_agent("SpecCacheMemoAgent", -> { cached })
      server.reply(json: message("Kept."))
      klass = asking("SpecCacheMemoWorkflow")
      memo.crash = crash

      expect { klass.new(context: {}).run_persisted!("run-cache", adapter:) }.to raise_error(crash)

      memo.crash = nil
      cached = true
      done = klass.restore("run-cache", adapter:).run_persisted!("run-cache", adapter:)

      expect([done.context[:answer], server.requests.length]).to eq(["Kept.", 1])
      expect(server.requests.first.body["system"].first).not_to have_key("cache_control")
    end

    it "gives a replay the kept answer though it marks the whole request for the cache where the first call did not" do
      cached = false
      agent("SpecCacheParamsAgent") do
        params { cached ? { max_tokens: 500, cache_control: { type: "ephemeral" } } : { max_tokens: 500 } }
      end
      server.reply(json: message("Kept."))
      klass = asking("SpecCacheParamsWorkflow")
      memo.crash = crash

      expect { klass.new(context: {}).run_persisted!("run-cache-params", adapter:) }.to raise_error(crash)

      memo.crash = nil
      cached = true
      done = klass.restore("run-cache-params", adapter:).run_persisted!("run-cache-params", adapter:)

      expect([done.context[:answer], server.requests.length]).to eq(["Kept.", 1])
    end

    it "keeps apart two calls whose tool inputs differ, though one looks like a marker" do
      chat = Struct.new(:model, :messages, :tools, :schema, :params)
      model = Struct.new(:id, :provider).new("claude-haiku-5-5", :anthropic)
      call = lambda do |input|
        blocks = [{ "type" => "tool_use", "id" => "t1", "name" => "find", "input" => input }]
        reply = RubyLLM::Message.new(role: :assistant, content: RubyLLM::Content::Raw.new(blocks))
        chat.new(model, [reply], {}, nil, {})
      end

      expect(Smith::ResponseMemo.request_digest(call.call({ "cache_control" => { "type" => "ephemeral" } })))
        .not_to eq(Smith::ResponseMemo.request_digest(call.call({})))
    end

    it "still sends again a call whose instructions changed" do
      text = "Be brief."
      agent("SpecCacheChangedAgent") { instructions { text } }
      server.reply(json: message("First.")).reply(json: message("Second."))
      klass = asking("SpecCacheChangedWorkflow")
      memo.crash = crash

      expect { klass.new(context: {}).run_persisted!("run-changed", adapter:) }.to raise_error(crash)

      memo.crash = nil
      text = "Be thorough."
      done = klass.restore("run-changed", adapter:).run_persisted!("run-changed", adapter:)

      expect([done.context[:answer], server.requests.length]).to eq(["Second.", 2])
    end
  end

  describe "a batch request" do
    let(:params) do
      { "model" => "claude-haiku-5-5",
        "system" => [{ "type" => "text", "text" => "Be brief.", "cache_control" => { "type" => "ephemeral" } }],
        "messages" => [{ "role" => "user", "content" => "Hi" }] }
    end
    let(:headers) { { "anthropic-version" => "2023-06-01" } }
    let(:uncached) { params.merge("system" => [{ "type" => "text", "text" => "Be brief." }]) }

    it "is the same request with or without cache markers, and another once what it asks changes" do
      digest = Smith::Batch.digest("params" => params, "headers" => headers)

      expect(Smith::Batch.changed?(digest, uncached, headers)).to be(false)
      expect(Smith::Batch.changed?(digest, params, headers)).to be(false)
      expect(Smith::Batch.changed?(digest, uncached.merge("messages" => [{ "role" => "user", "content" => "Bye" }]),
                                   headers)).to be(true)
    end

    it "is another request once a tool's schema changes, though the change looks like a marker" do
      tool = { "name" => "find", "input_schema" => { "type" => "object", "default" => {} } }
      digest = Smith::Batch.digest("params" => uncached.merge("tools" => [tool]), "headers" => headers)
      marker_shaped = { "cache_control" => { "type" => "ephemeral" } }
      marked = tool.merge("input_schema" => tool["input_schema"].merge("default" => marker_shaped))

      expect(Smith::Batch.changed?(digest, uncached.merge("tools" => [marked]), headers)).to be(true)
    end

    it "still matches a digest Smith 0.12.2 took with its markers, as the request was" do
      digest = Digest::SHA256.hexdigest(JSON.generate([params, headers]))

      expect(Smith::Batch.changed?(digest, params, headers)).to be(false)
      expect(Smith::Batch.changed?(digest, params.merge("model" => "claude-sonnet-5-5"), headers)).to be(true)
    end
  end

  describe "a seed's drift check" do
    let(:adapter) { Smith::PersistenceAdapters::Memory.new }
    let(:cached) { [] }
    let(:seeded) do
      flags = cached
      with_stubbed_class("SpecCacheSeedWorkflow", workflow_class) do
        seed_validation :strict
        initial_state :idle
        seed_messages { [{ role: :user, content: [Smith::Content.text("Read this.", cache: flags.any?)] }] }
        transition :finish, from: :idle, to: :done do
          compute { |step| step.write_context(:done, true) }
        end
      end
    end

    it "takes a seed whose parts are now cached, or no longer, as the same seed" do
      seeded.new(context: {}).persist!("run-seed", adapter:)
      cached << :warm

      expect(seeded.restore("run-seed", adapter:)).to be_a(seeded)
    end

    it "still matches a seed digest Smith 0.12.2 took with its parts' cache flags, as the seed was" do
      cached << :warm
      allow(Smith::CacheMarkers).to receive(:strip_parts) { |messages| messages }
      seeded.new(context: {}).persist!("run-old-seed", adapter:)
      allow(Smith::CacheMarkers).to receive(:strip_parts).and_call_original

      expect(seeded.restore("run-old-seed", adapter:)).to be_a(seeded)

      cached.clear
      expect { seeded.restore("run-old-seed", adapter:) }.to raise_error(Smith::SeedMismatch)
    end
  end
end
