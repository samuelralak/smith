# frozen_string_literal: true

require "stringio"

# RubyLLM's public touch points Smith relies on (slice-1a design, section
# 18), each asserted through RubyLLM's public interface only, so a RubyLLM
# release that changes one fails here, loudly, before a host notices. Started
# by slice 0 with what the recorder seam and the shared harness use; later
# slices add theirs.
RSpec.describe "RubyLLM contract: the public touch points Smith uses" do
  let(:server) { SseServer.new }

  around do |example|
    config = RubyLLM.config
    keys = %i[anthropic_api_key anthropic_api_base openai_api_key openai_api_base max_retries]
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
end
