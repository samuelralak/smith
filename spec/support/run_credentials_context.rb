# frozen_string_literal: true

require "logger"
require "securerandom"
require "stringio"

# Run credentials over the local server answering as Anthropic and OpenAI:
# a canary key the runs' blocks return, a different key in RubyLLM's global
# configuration (so a request that falls through to it shows), loggers kept
# for the leak checks, and helpers for agents and workflows.
RSpec.shared_context "with run credentials" do
  let(:server) { SseServer.new }
  let(:canary) { "sk-canary-#{SecureRandom.hex(16)}" }
  let(:global_key) { "global-canary-#{SecureRandom.hex(8)}" }
  let(:smith_log) { StringIO.new }
  let(:ruby_llm_log) { StringIO.new }
  let(:block_calls) { [] }
  let(:credentials) do
    Smith::ProviderCredentials.new(anthropic: { api_key: canary, api_base: server.url },
                                   openai: { api_key: canary, api_base: "#{server.url}/v1" })
  end

  around do |example|
    config = RubyLLM.config
    keys = %i[anthropic_api_key anthropic_api_base openai_api_key openai_api_base max_retries log_level
              instrumenter openai_use_system_role log_stream_debug]
    saved = keys.to_h { [_1, config.public_send(_1)] }
    saved_smith = %i[pricing logger run_launcher interrupting_errors require_run_credentials
                     run_credentials_instrumenter].to_h { [_1, Smith.config.public_send(_1)] }
    example.run
  ensure
    server.close
    Smith.config.require_run_credentials = false
    saved.each { |key, value| config.public_send(:"#{key}=", value) }
    saved_smith.each { |key, value| Smith.config.public_send(:"#{key}=", value) }
  end

  before do
    RubyLLM.configure do |config|
      config.anthropic_api_key = global_key
      config.anthropic_api_base = server.url
      config.openai_api_key = global_key
      config.openai_api_base = "#{server.url}/v1"
      config.max_retries = 0
      config.log_level = Logger::INFO
    end
    # RubyLLM's logger is global and memoized: its lines, at INFO, are read here.
    allow(RubyLLM).to receive(:logger).and_return(Logger.new(ruby_llm_log, level: Logger::INFO))
    Smith.config.logger = Logger.new(smith_log)
    allow_any_instance_of(Smith::Workflow).to receive(:sleep)
  end

  def message(text, id: "msg_1", model: "claude-sonnet-5-5", tokens: [100, 20])
    { "id" => id, "type" => "message", "role" => "assistant", "model" => model,
      "content" => [{ "type" => "text", "text" => text }], "stop_reason" => "end_turn",
      "usage" => { "input_tokens" => tokens.first, "output_tokens" => tokens.last } }
  end

  def openai_message(text, model: "gpt-5")
    { "id" => "chatcmpl-1", "object" => "chat.completion", "model" => model,
      "choices" => [{ "index" => 0, "finish_reason" => "stop",
                      "message" => { "role" => "assistant", "content" => text } }],
      "usage" => { "prompt_tokens" => 10, "completion_tokens" => 2, "total_tokens" => 12 } }
  end

  def anthropic_error(type, text) = { "type" => "error", "error" => { "type" => type, "message" => text } }

  def keys_sent = server.requests.map { _1.headers["x-api-key"] || _1.headers["authorization"] }

  def agent(name, register:, model: "claude-sonnet-5-5", provider: :anthropic, fallbacks: nil, &body)
    Smith::Agent::Registry.delete(register)
    with_stubbed_class(name, Smith::Agent) do
      register_as register
      model model, provider:, assume_model_exists: true
      params max_tokens: 500
      fallback_models(*fallbacks) if fallbacks
      class_exec(&body) if body
    end
  end

  # A one-step workflow asking `agent`; `credentialed` gives it a
  # provider_credentials block (recording each call) over `scope` keys.
  def asking(name, agent:, scope: [:project_id], credentialed: true, returning: -> { credentials }, &body)
    calls = block_calls
    with_stubbed_class(name, Smith::Workflow) do
      initial_state :idle
      state :done
      state :failed
      if credentialed
        provider_credentials(*scope) do |given|
          calls << given
          returning.call
        end
      end
      seed_messages { |_context| [{ role: :user, content: "classify this posting" }] }
      transition :ask, from: :idle, to: :done do
        execute agent, output_to: :answer
        on_failure :fail
      end
      class_exec(&body) if body
    end
  end
end
