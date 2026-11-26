# frozen_string_literal: true

require "active_support/notifications"
require "json"
require "open3"
require "tmpdir"

# Where a run's credentials reach (additions design 3.4 and 3.9): a nested
# workflow's own declaration, RubyLLM's instrumentation, the eval seam's
# skipped candidates, a restore in another process, and a run without them,
# which sees the very errors it saw before.
RSpec.describe "Run credentials, on every path" do
  include_context "with run credentials"

  let(:context) { { project_id: "proj_42" } }

  before { agent("SpecPathAgent", register: :spec_path_agent) }

  it "gives a nested workflow that declares its own its own scope, from the context it is given" do
    nested_calls = []
    own = Smith::ProviderCredentials.new(anthropic: { api_key: "#{canary}-own", api_base: server.url })
    child = asking("SpecOwnNested", agent: :spec_path_agent, credentialed: false) do
      provider_credentials(:project_id) do |scope|
        nested_calls << scope
        own
      end
    end
    parent = asking("SpecOwnParent", agent: :spec_path_agent) do
      state :nested
      transition :ask, from: :idle, to: :nested do
        workflow child
        on_failure :fail
      end
      transition :close, from: :nested, to: :done do
        execute :spec_path_agent, output_to: :answer
        on_failure :fail
      end
    end
    server.reply(json: message("nested")).reply(json: message("parent"))

    expect(parent.new(context: context).run!.state).to eq(:done)
    expect(keys_sent).to eq(["#{canary}-own", canary])
    expect([nested_calls, block_calls]).to eq([[{ "project_id" => "proj_42" }], [{ "project_id" => "proj_42" }]])
  end

  describe "RubyLLM's instrumentation" do
    let(:seen) { [] }

    around do |example|
      subscriber = ActiveSupport::Notifications.subscribe("request.ruby_llm") { |*event| seen << event.last }
      example.run
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    before { RubyLLM.config.instrumenter = ActiveSupport::Notifications }

    def refused
      server.reply(json: anthropic_error("authentication_error", "invalid x-api-key #{canary}"),
                   status: "401 Unauthorized")
    end

    it "reaches no subscriber from a credentialed run, its 401 included" do
      refused
      result = asking("SpecQuietFlow", agent: :spec_path_agent).new(context: context).run!

      expect(result.last_error).to be_a(Smith::ProviderCredentialsRefused)
      expect([server.requests.length, seen]).to eq([1, []])
    end

    it "still reaches subscribers from a run without credentials, and from a credentialed one set to :keep" do
      server.reply(json: message("ok"))
      asking("SpecLoudFlow", agent: :spec_path_agent, credentialed: false).new(context: context).run!
      Smith.config.run_credentials_instrumenter = :keep
      refused
      asking("SpecKeptFlow", agent: :spec_path_agent).new(context: context).run!

      expect(seen.map { _1[:provider] }).to eq(%w[anthropic anthropic])
      expect(seen.last[:exception_object]).to be_a(RubyLLM::UnauthorizedError)
    end
  end

  describe "the eval seam" do
    let(:observer) do
      Class.new do
        attr_reader :seen

        def initialize = @seen = []
        def attempt_finished(observation) = @seen << observation
      end.new
    end

    around do |example|
      AttemptObserverSlot.emptied do
        Smith::AttemptObservation.install(observer)
        trace = Smith.config.trace_adapter
        Smith.config.trace_adapter = Smith::Trace::Memory.new
        example.run
      ensure
        Smith.config.trace_adapter = trace
      end
    end

    it "observes a skipped candidate before the fallback's attempt: one per trace, plus one per skip" do
      only_openai = Smith::ProviderCredentials.new(openai: { api_key: canary, api_base: "#{server.url}/v1" })
      agent("SpecSeamAgent", register: :spec_seam_agent, fallbacks: [{ model: "gpt-5", provider: :openai }])
      server.reply(json: openai_message("ok"))
      klass = asking("SpecSeamFlow", agent: :spec_seam_agent, returning: -> { only_openai })
      Smith::Attribution.with(trial: "trial-1") { klass.new(context: context).run! }
      traces = Smith.config.trace_adapter.traces.select { _1[:type] == :provider_call }
      skipped, completed = observer.seen

      expect(observer.seen.length).to eq(traces.length + 1)
      expect([skipped.outcome, skipped.model, skipped.provider, skipped.attempt_index, skipped.messages])
        .to eq([:skipped, "claude-sonnet-5-5", :anthropic, 0, []])
      expect(skipped.failure).to eq(kind: :credentials_missing, error_class: "Smith::ProviderCredentialsMissing",
                                    message: "no key for this provider")
      expect(skipped.attempt_id).to match(/\A\h{8}-\h{4}-4\h{3}-\h{4}-\h{12}\z/)
      expect([completed.outcome, completed.model, completed.attempt_id]).to eq([:completed, "gpt-5",
                                                                                traces.sole[:data][:attempt_id]])
    end

    it "attempts a model the registry does not know, as a run without credentials does, rather than skip it" do
      only_openai = Smith::ProviderCredentials.new(openai: { api_key: canary, api_base: "#{server.url}/v1" })
      Smith::Agent::Registry.delete(:spec_unknown_agent)
      with_stubbed_class("SpecUnknownAgent", Smith::Agent) do
        register_as :spec_unknown_agent
        model "no-such-model-1"
        fallback_models({ model: "gpt-5", provider: :openai })
      end
      server.reply(json: openai_message("ok"))
      klass = asking("SpecUnknownFlow", agent: :spec_unknown_agent, returning: -> { only_openai })
      result = Smith::Attribution.with(trial: "trial-2") { klass.new(context: context).run! }

      expect(result.state).to eq(:done)
      expect(observer.seen.map { [_1.outcome, _1.failure&.fetch(:kind)] })
        .to eq([%i[failed model_unavailable], [:completed, nil]])
    end

    it "observes nothing outside a trial, and draws the skip's id whether or not anything observes it" do
      only_openai = Smith::ProviderCredentials.new(openai: { api_key: canary, api_base: "#{server.url}/v1" })
      agent("SpecDrawAgent", register: :spec_draw_agent, fallbacks: [{ model: "gpt-5", provider: :openai }])
      klass = asking("SpecDrawFlow", agent: :spec_draw_agent, returning: -> { only_openai })
      draws = lambda do
        count = 0
        allow(SecureRandom).to(receive(:uuid).and_wrap_original { |original| (count += 1) && original.call })
        server.reply(json: openai_message("ok"))
        klass.new(context: context).run!
        count
      end
      observed = draws.call
      Smith::AttemptObservation.uninstall(observer)

      expect(draws.call).to eq(observed)
      expect(observer.seen).to eq([])
    end
  end

  it "asks the block once in a fresh process with the saved scope, after a restore" do
    script = <<~RUBY
      require "json"
      require "smith"
      SERVER, KEY, PATH = ARGV
      RubyLLM.configure { _1.max_retries = 0 }
      class SpecFreshAgent < Smith::Agent
        register_as :spec_fresh_agent
        model "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true
      end
      CALLS = []
      class SpecFreshFlow < Smith::Workflow
        initial_state :idle
        state :done
        provider_credentials(:project_id) do |scope|
          CALLS << scope
          Smith::ProviderCredentials.new(anthropic: { api_key: KEY, api_base: SERVER })
        end
        seed_messages { |_context| [{ role: :user, content: "classify" }] }
        transition :ask, from: :idle, to: :done do
          execute :spec_fresh_agent, output_to: :answer
        end
      end
      state = JSON.parse(File.read(PATH))
      workflow = SpecFreshFlow.from_state(state)
      result = workflow.run!
      print JSON.generate(state: result.state, calls: CALLS, scope: workflow.to_state[:provider_credentials_scope])
    RUBY
    klass = asking("SpecFreshFlow", agent: :spec_path_agent)
    server.reply(json: message("ok"))
    Dir.mktmpdir do |dir|
      path = File.join(dir, "run.json")
      File.write(path, JSON.generate(klass.new(context: context).to_state))
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script,
                                        server.url, canary, path)

      expect([status.success?, err]).to eq([true, ""])
      expect(JSON.parse(out)).to eq("state" => "done", "calls" => [{ "project_id" => "proj_42" }],
                                    "scope" => { "project_id" => "proj_42" })
      expect([keys_sent, block_calls]).to eq([[canary], []])
    end
  end

  describe "a run without credentials" do
    it "hands terminal_provider_error the very error the provider raised, and records today's text" do
      seen = []
      allow_any_instance_of(Smith::Workflow).to receive(:terminal_provider_error).and_wrap_original do |original, *args|
        seen << args.first
        original.call(*args)
      end
      server.reply(json: anthropic_error("authentication_error", "invalid x-api-key #{global_key}"),
                   status: "401 Unauthorized")
      workflow = asking("SpecUnchangedFlow", agent: :spec_path_agent, credentialed: false).new(context: context)
      result = workflow.run!

      expect(seen.map(&:class)).to eq([RubyLLM::UnauthorizedError])
      expect(seen.sole.response.request_headers["x-api-key"]).to eq(global_key)
      expect(result.last_error.class).to eq(Smith::ProviderPermanentFailure)
      expect(result.last_error.message).to eq("invalid x-api-key #{global_key}")
      expect(workflow.to_state[:last_failed_step][:error_message]).to eq("invalid x-api-key #{global_key}")
      expect(result.last_error.cause).to be(seen.sole)
    end
  end
end
