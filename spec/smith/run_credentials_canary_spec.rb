# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

# The canary matrix (additions design 3.10): each run's block returns a key
# "sk-canary-" and 32 random hex digits, and no sink a host or Smith keeps
# may hold it, or any 12-character run of it, or its masked form, while the
# wire shows it reached the provider. Sinks: every payload the persistence
# adapter is handed, the run result (inspect and JSON), usage entries,
# traces and events, Smith's logger and RubyLLM's at INFO, stream sink and
# batch queue deliveries, each raised error through its cause chain
# (full_message, detailed_message, inspect), the failure records, and
# workflow.inspect. And what the run keeps: no RubyLLM configuration,
# context, chat, provider or connection is reachable from it (each prints
# its keys on Ruby 4), nor any String holding the key, walked past RubyLLM's
# own `instance_variables` overrides; the run's binding, whose `inspect` is
# redacted and which holds its context by design, aside.
RSpec.describe "Run credentials, the canary matrix" do
  include_context "with run credentials"

  let(:context) { { project_id: "proj_42" } }
  let(:payloads) { [] }
  let(:events) { [] }
  let(:streamed) { [] }
  let(:queue) do
    Class.new do
      attr_reader :items

      def initialize = @items = []
      def enqueue(**request) = @items << request
    end.new
  end
  let(:adapter) do
    kept = payloads
    Class.new(Smith::PersistenceAdapters::Memory) do
      %i[store store_versioned replace_exact].each do |name|
        define_method(name) do |key, payload, *rest, **options|
          kept << payload
          super(key, payload, *rest, **options)
        end
      end
    end.new
  end

  around do |example|
    saved = %i[trace_adapter trace_content stream_sinks batch_queue].to_h { [_1, Smith.config.public_send(_1)] }
    example.run
  ensure
    saved.each { |key, value| Smith.config.public_send(:"#{key}=", value) }
  end

  before do
    Smith.config.trace_adapter = Smith::Trace::Memory.new
    Smith.config.trace_content = true
    Smith::Events.on(Smith::Event) { |event| events << event.to_h }
    sink = Class.new do
      define_method(:initialize) { |kept| @kept = kept }
      %i[start delta reset finish fail].each { |name| define_method(name) { |*args| @kept << [name, *args] } }
    end
    kept = streamed
    Smith.config.stream_sinks = { reply: ->(_info) { sink.new(kept) } }
    Smith.config.batch_queue = queue
    agent("SpecCanaryAgent", register: :spec_canary_agent)
    agent("SpecCanaryFallback", register: :spec_canary_fallback, fallbacks: [{ model: "gpt-5", provider: :openai }])
  end

  def windows(text = canary) = (0..(text.length - 12)).map { text[_1, 12] }
  def masked = "#{canary[0, 8]}#{"*" * (canary.length - 12)}#{canary[-4..]}"

  def leaked(text)
    text = text.to_s
    [canary, masked, *windows].find { text.include?(_1) }
  end

  def chain(error) = error ? [error, *chain(error.cause)] : []

  def told(error)
    chain(error).flat_map { [_1.full_message(highlight: false), _1.detailed_message(highlight: false), _1.inspect] }
  end

  # Every sink, as text, for workflows and what their host calls raised.
  def sinks(workflows, raised) = host_sinks.merge(logs, run_sinks(workflows), "errors" => errors(workflows, raised))

  def host_sinks
    { "payloads" => payloads.map { JSON.generate(_1) }, "traces" => Smith.config.trace_adapter.traces.map(&:inspect),
      "events" => events.map(&:inspect), "stream" => streamed.map(&:inspect), "batches" => queue.items.map(&:inspect) }
  end

  def logs = { "smith_log" => [smith_log.string], "ruby_llm_log" => [ruby_llm_log.string] }

  def results(workflows) = workflows.filter_map { _1.instance_variable_get(:@spec_result) }

  def run_sinks(workflows)
    { "results" => results(workflows).flat_map { [_1.inspect, JSON.generate(_1.to_h.except(:steps))] },
      "usage" => workflows.flat_map(&:usage_entries).map { _1.to_h.inspect },
      "failure_records" => workflows.map { JSON.generate(_1.to_state[:last_failed_step]) },
      "workflows" => workflows.map(&:inspect) }
  end

  def errors(workflows, raised)
    [*raised, *results(workflows).flat_map { |result| result.steps.filter_map { _1[:error] } }].flat_map { told(_1) }
  end

  def sent_with(key) = server.requests.any? { _1.headers.values_at("x-api-key", "authorization").join.include?(key) }

  def expect_no_canary(workflows, raised = [], sent: true)
    expect(leaking(workflows, raised)).to eq([])
    expect([sent_with(global_key), sent_with(canary)]).to eq([false, sent])
    expect(kept(workflows, raised)).to eq([])
  end

  def leaking(workflows, raised)
    sinks(workflows, raised).flat_map { |sink, texts| texts.filter_map { leaked(_1) && sink } }.uniq
  end

  def holders
    [RubyLLM::Configuration, RubyLLM::Context, RubyLLM::Chat, RubyLLM::Provider, RubyLLM::Connection,
     Faraday::Connection]
  end

  # What the run keeps that holds a key: RubyLLM objects that print theirs,
  # and Strings holding part of the canary, by the classes holding them.
  def kept(workflows, raised)
    bindings = workflows.filter_map { _1.instance_variable_get(:@smith_run_credentials) }
    reachable = ReachableObjects.new(roots(workflows, raised), skip: bindings)
    reachable.filter_map { |object, from| holding(object, from) }.uniq
  end

  def roots(workflows, raised)
    [*workflows, *results(workflows), *raised, *Thread.current.keys.map { Thread.current[_1] },
     *Fiber.current.storage.to_h.values, queue.items, events, streamed]
  end

  def holding(object, from)
    if holders.any? { object.is_a?(_1) } then "#{object.class} from #{from}"
    elsif object.is_a?(String) && leaked(object) then "a String from #{from}"
    end
  end

  def run_flow(klass, key: "run-1")
    workflow = klass.new(context: context)
    raised = []
    begin
      workflow.instance_variable_set(:@spec_result, workflow.run_persisted!(key, adapter:))
    rescue StandardError => e
      raised << e
    end
    [workflow, raised]
  end

  def flow(name, agent: :spec_canary_agent, returning: -> { credentials }, &) = asking(name, agent:, returning:, &)

  it "keeps the key out of every sink when the step succeeds" do
    server.reply(json: message("ok"))
    workflow, raised = run_flow(flow("SpecCanaryOk"))

    expect(raised).to eq([])
    expect_no_canary([workflow])
  end

  {
    "a 401 echoing the whole key" => ->(key) { "invalid x-api-key: #{key}" },
    "a 401 echoing it masked" => lambda { |key|
      "Incorrect API key provided: #{key[0, 8]}#{"*" * (key.length - 12)}#{key[-4..]}"
    }
  }.each do |label, text|
    it "keeps the key out of every sink after #{label}" do
      server.reply(json: anthropic_error("authentication_error", text.call(canary)), status: "401 Unauthorized")
      workflow, raised = run_flow(flow("SpecCanary401"))

      expect(workflow.to_state[:last_failed_step][:error_class]).to eq("Smith::ProviderCredentialsRefused")
      expect_no_canary([workflow], raised)
    end
  end

  it "keeps the key out of every sink after a 500 echoing it" do
    server.reply(json: anthropic_error("api_error", "upstream said #{canary} was odd"),
                 status: "500 Internal Server Error")
    workflow, raised = run_flow(flow("SpecCanary500"))

    expect(workflow.to_state[:last_failed_step][:error_message]).to include("[REDACTED]")
    expect_no_canary([workflow], raised)
  end

  it "keeps the key out of every sink after a 429 that a fallback answers" do
    server.reply(json: anthropic_error("rate_limit_error", "slow down #{canary}"), status: "429 Too Many Requests")
          .reply(json: openai_message("ok"))
    workflow, raised = run_flow(flow("SpecCanary429", agent: :spec_canary_fallback))

    expect(workflow.to_state[:state]).to eq(:done)
    expect(server.requests.map(&:path)).to eq(%w[/v1/messages /v1/chat/completions])
    expect_no_canary([workflow], raised)
  end

  it "keeps the key out of every sink across parallel branches and a nested workflow" do
    server.answer { { json: message("ok") } }
    nested = asking("SpecCanaryNested", agent: :spec_canary_agent, credentialed: false)
    klass = flow("SpecCanaryBranches") do
      state :fanned
      transition :ask, from: :idle, to: :fanned do
        execute :spec_canary_agent, parallel: true, count: 3
        on_failure :fail
      end
      transition :nest, from: :fanned, to: :done do
        workflow nested
        on_failure :fail
      end
    end
    workflow, raised = run_flow(klass)

    expect([workflow.to_state[:state], server.requests.length]).to eq([:done, 4])
    expect_no_canary([workflow], raised)
  end

  it "keeps the key out of every sink of a nested workflow fanned out over items, one of them failing" do
    room = asking("SpecCanaryRoom", agent: :spec_canary_agent, credentialed: false)
    klass = flow("SpecCanaryRooms") do
      transition :ask, from: :idle, to: :done do
        workflow room, over: ->(context) { context[:rooms] }, item_to: :room, concurrency: 1, output_to: :rooms
        on_failure :fail
      end
    end
    server.reply(json: message("ok"))
          .reply(json: anthropic_error("api_error", "upstream said #{canary} was odd"),
                 status: "500 Internal Server Error")
    workflow = klass.new(context: context.merge(rooms: %w[kitchen hall]))
    raised = []
    begin
      workflow.instance_variable_set(:@spec_result, workflow.run_persisted!("run-rooms", adapter:))
    rescue StandardError => e
      raised << e
    end

    expect(server.requests.length).to eq(2)
    expect(workflow.to_state[:state]).to eq(:failed)
    expect_no_canary([workflow], raised)
  end

  it "keeps the key out of every sink of an inline child run" do
    Smith.config.run_launcher = Smith::Launchers::Inline.new
    child = flow("SpecCanaryChild")
    klass = flow("SpecCanaryParent") do
      transition :ask, from: :idle, to: :done do
        call child, input: ->(context) { { project_id: context[:project_id] } }, timeout: 60, into: :child
        on_failure :fail
      end
    end
    server.reply(json: anthropic_error("authentication_error", "invalid #{canary}"), status: "401 Unauthorized")
    workflow, raised = run_flow(klass)

    expect(workflow.to_state[:state]).to eq(:failed)
    expect_no_canary([workflow], raised)
  end

  it "keeps the key out of every sink of a streamed step and a batch capture" do
    streaming = flow("SpecCanaryStream") do
      transition :ask, from: :idle, to: :done do
        execute :spec_canary_agent, output_to: :answer, stream: :reply
        on_failure :fail
      end
    end
    batching = flow("SpecCanaryBatch") do
      transition :ask, from: :idle, to: :done do
        execute :spec_canary_agent, output_to: :answer, mode: :batch
        on_failure :fail
      end
    end
    server.reply(events: [{ type: "error", error: { type: "authentication_error", message: "bad key #{canary}" } }])
    streamed_run, streamed_raised = run_flow(streaming)
    batched_run, batched_raised = run_flow(batching, key: "run-2")

    expect(streamed_run.to_state[:last_failed_step][:error_class]).to eq("Smith::ProviderCredentialsRefused")
    expect([queue.items.length, batched_run.waiting?]).to eq([1, true])
    expect_no_canary([streamed_run, batched_run], streamed_raised + batched_raised)
  end

  # A capture that fails before its request is thrown (an attachment the
  # provider takes none of) leaves no provider, and so no key, on the run.
  it "keeps the key out of every sink of a batch capture that fails before its request is thrown" do
    allow_any_instance_of(RubyLLM::Providers::Anthropic).to receive(:render_payload)
      .and_raise(RubyLLM::UnsupportedAttachmentError, "application/pdf")
    batching = flow("SpecCanaryBatchFails") do
      transition :ask, from: :idle, to: :done do
        execute :spec_canary_agent, output_to: :answer, mode: :batch
        on_failure :fail
      end
    end
    workflow, raised = run_flow(batching)

    expect([workflow.to_state[:state], queue.items]).to eq([:failed, []])
    expect_no_canary([workflow], raised, sent: false)
  end

  it "keeps the key out of every sink of an image agent whose paint the provider failed, echoing the key" do
    agent("SpecCanaryPainter", register: :spec_canary_painter, model: "gpt-image-test", provider: :openai) do
      image size: "1024x1024", quality: "low"
    end
    server.reply(json: { "error" => { "message" => "upstream echoed #{canary}", "type" => "server_error" } },
                 status: "500 Internal Server Error")
    workflow, raised = run_flow(flow("SpecCanaryPainting", agent: :spec_canary_painter))

    expect(server.requests.map(&:path)).to eq(["/v1/images/generations"])
    expect(workflow.to_state[:last_failed_step][:error_message]).to include("[REDACTED]")
    expect_no_canary([workflow], raised)
  end

  it "keeps the key out of every sink when the block raises with it in its message" do
    key = canary
    workflow, raised = run_flow(flow("SpecCanaryRaise", returning: -> { raise ArgumentError, "bad #{key}" }))

    expect(workflow.to_state[:last_failed_step][:error_class]).to eq("Smith::ProviderCredentialsError")
    expect_no_canary([workflow], raised, sent: false)
  end

  it "keeps the key out of every sink when the credentials miss the agent's provider" do
    only_gemini = Smith::ProviderCredentials.new(gemini: { api_key: canary })
    workflow, raised = run_flow(flow("SpecCanaryMissing", returning: -> { only_gemini }))

    expect(workflow.to_state[:last_failed_step][:error_class]).to eq("Smith::ProviderCredentialsMissing")
    expect_no_canary([workflow], raised, sent: false)
  end

  it "keeps the key out of every sink of a durable wait restored and run on in another process" do
    klass = flow("SpecCanaryWait") do
      state :ready
      transition :wait, from: :idle, to: :ready do
        await :source_ready, into: :source, timeout: 3600
        on_failure :fail
      end
      transition :ask, from: :ready, to: :done do
        execute :spec_canary_agent, output_to: :answer
        on_failure :fail
      end
    end
    workflow, raised = run_flow(klass)
    expect(workflow.waiting?).to be(true)
    script = <<~RUBY
      require "json"
      require "logger"
      require "stringio"
      require "smith"
      SERVER, KEY, PATH = ARGV
      SMITH_LOG = StringIO.new
      LLM_LOG = StringIO.new
      Smith.config.logger = Logger.new(SMITH_LOG)
      RubyLLM.configure do |config|
        config.max_retries = 0
        config.logger = Logger.new(LLM_LOG, level: Logger::INFO)
      end
      class SpecCanaryAgent < Smith::Agent
        register_as :spec_canary_agent
        model "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true
      end
      class SpecCanaryWait < Smith::Workflow
        initial_state :idle
        state :ready
        state :done
        state :failed
        provider_credentials(:project_id) do |_scope|
          Smith::ProviderCredentials.new(anthropic: { api_key: KEY, api_base: SERVER })
        end
        transition :wait, from: :idle, to: :ready do
          await :source_ready, into: :source, timeout: 3600
          on_failure :fail
        end
        transition :ask, from: :ready, to: :done do
          execute :spec_canary_agent, output_to: :answer
          on_failure :fail
        end
      end
      kept = []
      adapter = Class.new(Smith::PersistenceAdapters::Memory) do
        define_method(:store) { |key, payload, **options| kept << payload && super(key, payload, **options) }
        define_method(:store_versioned) do |key, payload, **options|
          kept << payload
          super(key, payload, **options)
        end
      end.new
      adapter.store("run-1", File.read(PATH))
      token = SpecCanaryWait.restore("run-1", adapter:).awaiting.token
      SpecCanaryWait.resume!("run-1", event: :source_ready, token:, payload: { text: "ok" }, adapter:)
      workflow = SpecCanaryWait.restore("run-1", adapter:)
      result = workflow.run_persisted!("run-1", adapter:)
      error = result.last_error
      chain = []
      while error
        chain << error.full_message(highlight: false) << error.inspect
        error = error.cause
      end
      print JSON.generate(state: result.state, sinks: [*kept.map(&:to_s), result.inspect, workflow.inspect,
                                                       SMITH_LOG.string, LLM_LOG.string, *chain])
    RUBY
    server.reply(json: anthropic_error("authentication_error", "invalid x-api-key #{canary}"),
                 status: "401 Unauthorized")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "run.json")
      File.write(path, adapter.fetch("run-1"))
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script,
                                        server.url, canary, path)
      expect([status.success?, err]).to eq([true, ""])
      child = JSON.parse(out)

      expect(child["state"]).to eq("failed")
      expect(child["sinks"].filter_map { leaked(_1) }).to eq([])
    end
    expect_no_canary([workflow], raised)
  end
end
