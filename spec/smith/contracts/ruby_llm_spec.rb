# frozen_string_literal: true

require "logger"
require "stringio"
require "smith/provider_options"

# RubyLLM's public touch points Smith relies on (slice-1a design, section
# 18), each asserted through RubyLLM's public interface only, so a RubyLLM
# release that changes one fails here, loudly, before a host notices. Started
# by slice 0 with what the recorder seam and the shared harness use; later
# slices add theirs. One exception, listed in section 18: the request hook a
# step's settings are read through (slice 1a.4) rests on 1.16's internal
# request path, so its example reads the chat's provider and wraps
# Connection#post; it is replaced at the 2.x move by RubyLLM's public request
# seam (`chat.render`, or a `before_request` callback).
RSpec.describe "RubyLLM contract: the public touch points Smith uses" do
  let(:server) { SseServer.new }

  around do |example|
    config = RubyLLM.config
    keys = %i[anthropic_api_key anthropic_api_base openai_api_key openai_api_base max_retries instrumenter]
    saved = keys.to_h { [_1, config.public_send(_1)] }
    example.run
  ensure
    server.close
    saved.each { |key, value| config.public_send(:"#{key}=", value) }
  end

  before do
    RubyLLM.configure do |config|
      config.anthropic_api_key = "test"
      config.anthropic_api_base = server.url
      config.openai_api_key = "test"
      config.openai_api_base = "#{server.url}/v1"
      config.max_retries = 0
    end
  end

  def anthropic_chat = RubyLLM.chat(model: "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true)

  def reply(content, stop: "end_turn")
    { "id" => "msg_1", "type" => "message", "role" => "assistant", "model" => "claude-sonnet-5-5",
      "content" => content, "stop_reason" => stop, "usage" => { "input_tokens" => 10, "output_tokens" => 2 } }
  end

  describe "the readers Smith::AttemptObservation::Transcript uses (as ResponseMemo and Budget::Continuation do)" do
    it "gives a chat's messages as RubyLLM::Message, each with its role, content, tool calls and thinking" do
      server.reply(json: reply([{ "type" => "thinking", "thinking" => "Look it up.", "signature" => "sig" },
                                { "type" => "tool_use", "id" => "toolu_1", "name" => "lookup",
                                  "input" => { "query" => "x" } }], stop: "tool_use"))
      chat = anthropic_chat
      chat.add_message(role: :user, content: "Find the hours.")
      tool = Class.new(RubyLLM::Tool) do
        def self.name = "Lookup"
        description "Looks a place up."
        param :query, type: :string
        def execute(query:) = "#{query} opens at 8"
      end
      server.reply(json: reply([{ "type" => "text", "text" => "Opens at 8." }]))
      chat.with_tool(tool).complete

      messages = chat.messages
      expect(messages).to all(be_a(RubyLLM::Message))
      expect(messages.map(&:role)).to eq(%i[user assistant tool assistant])
      call = messages[1].tool_calls
      expect(call).to be_a(Hash)
      expect(call.values.map { [_1.class, _1.id, _1.name, _1.arguments] })
        .to eq([[RubyLLM::ToolCall, "toolu_1", "lookup", { "query" => "x" }]])
      expect([messages[1].thinking.class, messages[1].thinking.text]).to eq([RubyLLM::Thinking, "Look it up."])
      expect([messages[2].tool_call_id, messages[2].content]).to eq(["toolu_1", "x opens at 8"])
      expect([messages[3].content, messages[3].tool_call_id, messages[3].tool_calls]).to eq(["Opens at 8.", nil, nil])
    end

    it "reads content as a String, a Content with text and attachments, a Raw value, or a parsed Hash" do
      upload = RubyLLM::Attachment.new(StringIO.new("%PDF-1.7"), filename: "terms.pdf")
      rich = RubyLLM::Message.new(role: :user, content: RubyLLM::Content.new("Read this.", [upload]))
      plain = RubyLLM::Message.new(role: :user, content: RubyLLM::Content.new("Just text."))
      blocks = [{ type: "text", text: "Cached.", cache_control: { type: "ephemeral" } }]
      raw = RubyLLM::Message.new(role: :user, content: RubyLLM::Content::Raw.new(blocks))
      parsed = RubyLLM::Message.new(role: :assistant, content: "").tap { _1.content = { "label" => "bug" } }

      expect(plain.content).to eq("Just text.")
      expect([rich.content.class, rich.content.text, rich.content.attachments.length])
        .to eq([RubyLLM::Content, "Read this.", 1])
      attachment = rich.content.attachments.sole
      expect([attachment.filename, attachment.mime_type, attachment.io_like?, attachment.path?,
              attachment.source.size]).to eq(["terms.pdf", "application/pdf", true, false, 8])
      expect([raw.content.class, raw.content.value]).to eq([RubyLLM::Content::Raw, blocks])
      expect(parsed.content).to eq("label" => "bug")
      remote = RubyLLM::Attachment.new("https://example.test/terms.pdf")
      expect([remote.url?, remote.path?, remote.io_like?, remote.filename]).to eq([true, false, false, "terms.pdf"])
    end

    it "parses a reply under a schema into a Hash, the form a structured reply's message keeps" do
      schema = Class.new do
        def to_json_schema
          { name: "label", schema: { type: "object", required: ["label"], properties: { label: { type: "string" } } } }
        end
      end
      server.reply(json: reply([{ "type" => "text", "text" => '{"label":"bug"}' }]))

      answer = anthropic_chat.with_schema(schema).ask("Label it.")
      expect(answer.content).to eq("label" => "bug")
    end

    it "answers a paint with a RubyLLM::Image whose data is the image as base64, which its digest is read from" do
      drawn = "\x89PNG\r\n\x1A\ndrawn".b
      server.reply(json: { "created" => 1, "data" => [{ "b64_json" => [drawn].pack("m0") }] })

      image = RubyLLM::Image.paint("Draw a cat.", model: "gpt-image-test", provider: :openai, assume_model_exists: true)
      expect([image.class, image.data.unpack1("m")]).to eq([RubyLLM::Image, drawn])
      expect(server.requests.sole.path).to eq("/v1/images/generations")
    end
  end

  # Slice 1a.4: a step record's settings are read from each request where
  # it leaves (AttemptObservation::Sending, prepended on Connection#post):
  # the listed exception above, pinned to 1.16.
  describe "where a request leaves for its provider" do
    it "posts each request's payload, its params merged in, through its provider's Connection#post" do
      server.reply(json: reply([{ "type" => "text", "text" => "Sent." }]))
      chat = anthropic_chat.with_temperature(0.2).with_params(max_tokens: 64)
      provider = chat.instance_variable_get(:@provider)
      posted = []
      allow(provider.connection).to receive(:post).and_wrap_original do |post, url, payload, &block|
        posted << [url, payload.slice(:temperature, :max_tokens)]
        post.call(url, payload, &block)
      end

      expect(chat.ask("Hi").content).to eq("Sent.")
      own = RubyLLM::Connection.instance_method(:post)
      own = own.super_method until own.owner == RubyLLM::Connection
      expect(own.parameters).to eq([%i[req url], %i[req payload], %i[block &]])
      expect(posted).to eq([["v1/messages", { temperature: 0.2, max_tokens: 64 }]])
      expect([provider.connection.provider.equal?(provider), provider.class.slug]).to eq([true, "anthropic"])
    end
  end

  describe "the *_api_base options the shared harness points at its local server" do
    it "sends each provider's requests to the base it is given" do
      server.reply(json: reply([{ "type" => "text", "text" => "From Anthropic." }]))
      server.reply(json: { "id" => "c1", "object" => "chat.completion", "model" => "gpt-5",
                           "choices" => [{ "index" => 0, "finish_reason" => "stop",
                                           "message" => { "role" => "assistant", "content" => "From OpenAI." } }],
                           "usage" => { "prompt_tokens" => 3, "completion_tokens" => 2 } })

      expect(anthropic_chat.ask("Hi").content).to eq("From Anthropic.")
      expect(RubyLLM.chat(model: "gpt-5", provider: :openai, assume_model_exists: true).ask("Hi").content)
        .to eq("From OpenAI.")
      expect(server.requests.map { [_1.verb, _1.path] }).to eq([%w[POST /v1/messages], %w[POST /v1/chat/completions]])
    end
  end

  describe "the public errors Smith's failure handling, and so the seam's failure kinds, read" do
    it "raises one class per provider status, keeping the response's status" do
      expected = { 400 => RubyLLM::BadRequestError, 401 => RubyLLM::UnauthorizedError,
                   402 => RubyLLM::PaymentRequiredError, 403 => RubyLLM::ForbiddenError, 404 => RubyLLM::Error,
                   429 => RubyLLM::RateLimitError, 500 => RubyLLM::ServerError,
                   503 => RubyLLM::ServiceUnavailableError, 529 => RubyLLM::OverloadedError }

      expected.each do |status, error_class|
        server.reply(json: { "type" => "error", "error" => { "type" => "error", "message" => "status #{status}" } },
                     status: "#{status} Status")
        error = begin
          anthropic_chat.ask("Hi")
        rescue RubyLLM::Error => e
          e
        end
        expect([error.class, error.response.status, error.message]).to eq([error_class, status, "status #{status}"])
      end
    end

    it "keeps the errors that are not a provider's reply apart from RubyLLM::Error" do
      expect(RubyLLM::ModelNotFoundError.ancestors).not_to include(RubyLLM::Error)
      expect(RubyLLM::UnsupportedAttachmentError.ancestors).not_to include(RubyLLM::Error)
      expect(RubyLLM::UnsupportedAttachmentError.new("pdf")).to be_a(StandardError)
    end
  end

  # Run credentials (slice 1c), most through Smith::ProviderOptions (its
  # header lists every touch point, those outside it included). These are
  # the upgrade gate: RubyLLM's pin moves only once they pass on the new
  # version, with spec/smith/contracts/run_credentials_providers_spec.rb.
  describe "the context, options and errors run credentials use" do
    def with_key(key) = RubyLLM.context { _1.anthropic_api_key = key }

    def sent_key = server.requests.last.headers["x-api-key"]

    it "isolates a context's configuration: two contexts send their own keys, and the global is unchanged" do
      2.times { server.reply(json: reply([{ "type" => "text", "text" => "ok" }])) }
      first = with_key("first-key")
      second = with_key("second-key")

      expect(first).to be_a(RubyLLM::Context)
      RubyLLM.chat(model: "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true, context: first)
             .ask("Hi")
      expect(sent_key).to eq("first-key")
      RubyLLM::Chat.new(model: "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true)
                   .with_context(second).ask("Hi")
      expect(sent_key).to eq("second-key")
      expect(RubyLLM.config.anthropic_api_key).to eq("test")
    end

    it "builds an agent's chat on the context given to RubyLLM::Agent.chat, a keyword that is not its input" do
      server.reply(json: reply([{ "type" => "text", "text" => "ok" }]))
      agent = Class.new(RubyLLM::Agent) do
        model "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true
        inputs :topic
      end
      RubyLLM.config.anthropic_api_key = nil

      chat = agent.chat(topic: "x", context: with_key("agent-key"))
      chat.ask("Hi")
      expect(sent_key).to eq("agent-key")
    end

    it "lists each registered provider's options, every one classified in ProviderOptions::TABLE" do
      table = Smith::ProviderOptions::TABLE
      listed = RubyLLM::Provider.providers.to_h do |slug, klass|
        [slug, klass.configuration_options.map { _1.to_s.delete_prefix("#{slug}_").to_sym }]
      end

      expect(listed.transform_values(&:sort)).to eq(table.transform_values { _1.keys.sort })
      expect(table.values.flat_map(&:values).uniq.sort).to eq(%i[endpoint secret setting])
      credentials = Smith::ProviderOptions::CREDENTIALS
      expect(credentials.keys.sort).to eq(table.keys.sort)
      expect(credentials.flat_map { |slug, sets| sets.flatten.map { table.dig(slug, _1) } }.uniq).to eq([:secret])
      named = listed.flat_map { |slug, names| names.map { |name| :"#{slug}_#{name}" } }
      expect(RubyLLM::Configuration.options).to include(*named)
      listed.each_key do |slug|
        expect(RubyLLM::Provider.resolve(slug)).to be(RubyLLM::Provider.providers[slug])
        requirements = RubyLLM::Provider.resolve(slug).configuration_requirements
        expect(requirements.map { _1.to_s.delete_prefix("#{slug}_").to_sym } - table[slug].keys).to eq([])
      end
    end

    it "emits nothing to the global instrumenter from a context whose instrumenter is nil" do
      seen = []
      RubyLLM.config.instrumenter = Class.new do
        define_method(:instrument) do |name, payload = {}, &block|
          seen << name
          block&.call(payload)
        end
      end.new
      2.times { server.reply(json: reply([{ "type" => "text", "text" => "ok" }])) }
      quiet = Smith::ProviderOptions.context({ anthropic_api_key: "k", anthropic_api_base: server.url },
                                             instrumenter: false)
      RubyLLM.chat(model: "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true, context: quiet)
             .ask("Hi")
      expect(seen).to eq([])
      anthropic_chat.ask("Hi")
      expect(seen).to include("chat.ruby_llm", "request.ruby_llm")
    ensure
      RubyLLM.config.instrumenter = nil
    end

    # RubyLLM logs with one logger, kept once used: config.logger when set
    # (a Rails host's Rails.logger), else a Logger at config.log_level, which
    # takes an Integer, a Symbol or a String; and writes response bodies when
    # that logger is at DEBUG.
    it "logs with config.logger or a Logger at log_level, kept once used, and writes bodies at DEBUG" do
      kept = RubyLLM.instance_variable_get(:@logger)
      level = RubyLLM.config.log_level
      host = Logger.new(StringIO.new, level: :info)
      RubyLLM.remove_instance_variable(:@logger) if RubyLLM.instance_variable_defined?(:@logger)
      RubyLLM.config.logger = host
      expect([RubyLLM.logger, RubyLLM.instance_variable_get(:@logger)]).to eq([host, host])

      RubyLLM.remove_instance_variable(:@logger)
      RubyLLM.config.logger = nil
      [Logger::DEBUG, :debug, "DEBUG"].each do |given|
        RubyLLM.config.log_level = given
        expect(Smith::ProviderOptions.body_logging).to include("log_level"), given.inspect
        built = Logger.new(IO::NULL, level: RubyLLM.config.log_level)
        expect(built.debug?).to be(true), given.inspect
      end

      io = StringIO.new
      RubyLLM.instance_variable_set(:@logger, Logger.new(io, level: :debug))
      server.reply(json: reply([{ "type" => "text", "text" => "ok" }]))
      anthropic_chat.ask("a body to log")
      expect(io.string).to include("a body to log")
    ensure
      RubyLLM.instance_variable_set(:@logger, kept)
      RubyLLM.config.logger = nil
      RubyLLM.config.log_level = level
    end

    it "reads log_stream_debug, and no body logging at INFO" do
      stream = RubyLLM.config.log_stream_debug
      RubyLLM.config.log_stream_debug = true
      expect(Smith::ProviderOptions.body_logging).to include("log_stream_debug")
      RubyLLM.config.log_stream_debug = false
      expect(Smith::ProviderOptions.body_logging).to be_nil
    ensure
      RubyLLM.config.log_stream_debug = stream
    end

    # The prompt seam (slice 4): a named prompt is an instructions block,
    # filled in from the inputs in the fiber building the chat, whose
    # fiber-local state holds the version Smith sends.
    it "runs an instructions block as it builds a chat, in its fiber, inputs as methods, copied to subclasses" do
      seen = []
      agent = Class.new(RubyLLM::Agent) do
        model "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true
        inputs :person
        instructions { (seen << [Fiber.current, person]) && "For #{person}." }
      end
      chat = agent.chat(person: "Ada")
      Class.new(agent).chat(person: "Bo")

      expect(seen).to eq([[Fiber.current, "Ada"], [Fiber.current, "Bo"]])
      expect(chat.messages.map { [_1.role, _1.content] }).to eq([[:system, "For Ada."]])
    end

    it "reads an agent class's own context and inputs, which would replace a run's context" do
      own = RubyLLM.context
      agent = Class.new(RubyLLM::Agent) do
        context own
        inputs :topic, :context
      end

      expect([agent.context, agent.inputs]).to eq([own, %i[topic context]])
      expect([RubyLLM::Agent.context, Class.new(RubyLLM::Agent).inputs]).to eq([nil, []])
    end

    # A batch result's usage is read without a provider, so without any
    # key: a worker serving many accounts' keys keeps none globally.
    it "parses an Anthropic message on its chat module, with no provider or configuration" do
      response = Struct.new(:body).new(reply([{ "type" => "text", "text" => "ok" }]))
      message = RubyLLM::Providers::Anthropic::Chat.parse_completion_response(response)

      expect([message.content, message.input_tokens, message.output_tokens]).to eq(["ok", 10, 2])
    end

    it "copies an error through its public constructor: its class, the given text and status, read as before" do
      reader = Object.new.extend(Smith::Agent::ProviderFailureHandling)
      readings = lambda do |error|
        %i[provider_account_failure? model_permission_failure? model_unavailable? transient_failure?
           fallback_eligible?].map { reader.send(_1, error) }
      end
      { 401 => RubyLLM::UnauthorizedError, 402 => RubyLLM::PaymentRequiredError, 403 => RubyLLM::ForbiddenError,
        404 => RubyLLM::Error, 429 => RubyLLM::RateLimitError, 529 => RubyLLM::OverloadedError }.each do |status, klass|
        server.reply(json: { "type" => "error", "error" => { "type" => "error", "message" => "said" } },
                     status: "#{status} Status")
        original = begin
          anthropic_chat.ask("Hi")
        rescue RubyLLM::Error => e
          e
        end
        copy = Smith::ProviderOptions.copy(original, status:, body: "body", message: "text")

        expect([copy.class, copy.message, copy.response.status,
                copy.response.body]).to eq([klass, "text", status, "body"])
        expect([copy.cause, copy.backtrace]).to eq([nil, original.backtrace])
        expect(readings.call(copy)).to eq(readings.call(original))
        expect(Smith::BillingRefusals.classified(copy)).to be(copy)
      end
    end

    it "names the provider RubyLLM's model registry gives a model, and none for a model it does not know" do
      expect(Smith::ProviderOptions.provider_of("claude-sonnet-4-5")).to eq(:anthropic)
      expect(Smith::ProviderOptions.provider_of("gpt-4o")).to eq(:openai)
      expect(Smith::ProviderOptions.provider_of("no-such-model")).to be_nil
    end
  end
end
