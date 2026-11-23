# frozen_string_literal: true

require "json"
require "open3"
require "pp"

# Each run uses its own provider credentials (additions design, section 3):
# a workflow class names scope keys and a block; the run keeps the scope,
# never a key; the block is asked at the first request in each process; the
# run's requests go out on a RubyLLM context holding only its credentials.
RSpec.describe "Run credentials" do
  include_context "with run credentials"

  let(:context) { { project_id: "proj_42" } }

  def run(klass, given = context)
    workflow = klass.new(context: given)
    [workflow, workflow.run!]
  end

  describe "loading" do
    def child(script)
      lib = File.expand_path("../../lib", __dir__)
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", "require 'json'\n#{script}")
      raise "child failed: #{err}" unless status.success?

      JSON.parse(out)
    end

    it "loads nothing of run credentials on require \"smith\", and each part only when it is used" do
      facts = child(<<~RUBY)
        files = -> { $LOADED_FEATURES.grep(%r{/lib/smith/(provider_credentials|provider_options|run_credentials|scope)}) }
        require "smith"
        facts = { "on_require" => files.call.length, "autoload" => !Smith.autoload?(:ProviderCredentials).nil?,
                  "defined" => %i[RunCredentials ProviderOptions Scope].select { Smith.const_defined?(_1, false) } }
        Smith::ProviderCredentials
        facts["on_naming"] = files.call.map { File.basename(_1) }.sort
        Class.new(Smith::Workflow) { provider_credentials { nil } }
        facts["on_declaring"] = files.call.map { File.basename(_1) }.sort
        print JSON.generate(facts)
      RUBY

      expect(facts).to eq("on_require" => 0, "autoload" => true, "defined" => [],
                          "on_naming" => %w[provider_credentials.rb provider_options.rb],
                          "on_declaring" => %w[provider_credentials.rb provider_credentials_scrubber.rb
                                               provider_options.rb run_credentials.rb scope.rb])
    end
  end

  describe "declaring them" do
    it "keeps the scope keys and the block, for subclasses too, and reads nothing for a class without them" do
      block = proc { credentials }
      base = with_stubbed_class("SpecHostedRun", Smith::Workflow) { provider_credentials(:project_id, :tenant, &block) }
      child = Class.new(base)

      expect([base.provider_credentials,
              base.smith_provider_credentials_scope_keys]).to eq([block, %i[project_id tenant]])
      expect([child.provider_credentials,
              child.smith_provider_credentials_scope_keys]).to eq([block, %i[project_id tenant]])
      expect([Smith::Workflow.provider_credentials,
              Smith::Workflow.smith_provider_credentials_scope_keys]).to eq([nil, []])
    end

    it "refuses a declaration without a block, or with keys that cannot name a scope" do
      klass = Class.new(Smith::Workflow)

      expect { klass.provider_credentials(:project_id) }.to raise_error(ArgumentError, /needs a block/)
      expect { klass.provider_credentials("project_id") { nil } }.to raise_error(ArgumentError, /Symbols/)
      expect { klass.provider_credentials(:ProjectId) { nil } }.to raise_error(ArgumentError, /scope key/)
      expect { klass.provider_credentials(*(1..9).map { :"key_#{_1}" }) { nil } }.to raise_error(ArgumentError, /8/)
    end
  end

  describe "the scope" do
    it "is captured from the trusted context when the run is created and saved as Strings, never a key" do
      agent("SpecRunAgent", register: :spec_run_agent)
      server.reply(json: message("ok"))
      workflow, result = run(asking("SpecRunFlow", agent: :spec_run_agent))
      state = workflow.to_state

      expect(result.state).to eq(:done)
      expect(state[:provider_credentials_scope]).to eq("project_id" => "proj_42")
      expect(JSON.generate(state)).not_to include(canary)
      # The block gets the run's Smith::Scope itself: String keys, frozen.
      expect(block_calls).to eq([{ "project_id" => "proj_42" }])
      expect(block_calls.sole).to be_frozen
      expect(block_calls.sole).to equal(workflow.instance_variable_get(:@smith_run_credentials).scope)
    end

    it "is left out of the saved state of a class that does not declare them" do
      agent("SpecPlainAgent", register: :spec_plain_agent)
      server.reply(json: message("ok"))
      workflow, = run(asking("SpecPlainFlow", agent: :spec_plain_agent, credentialed: false))

      expect(workflow.to_state).not_to have_key(:provider_credentials_scope)
      expect(keys_sent).to eq([global_key])
    end

    it "refuses an untrusted key, and a value that is not a Smith::Scope value, when the run is created" do
      klass = asking("SpecScopeFlow", agent: :spec_scope_agent) do
        context_manager(Class.new(Smith::Context) { untrusted :project_id })
      end
      plain = asking("SpecScopeValues", agent: :spec_scope_agent)

      expect { klass.new(context: context) }.to raise_error(Smith::WorkflowError, /provider_credentials scope key/)
      expect { plain.new(context: { project_id: 42 }) }.to raise_error(Smith::ScopeInvalid)
      expect { plain.new(context: {}) }.to raise_error(Smith::ScopeInvalid)
      expect(block_calls).to eq([])
    end

    it "comes back with a restored run, and the block is asked again with it" do
      agent("SpecRestoreAgent", register: :spec_restore_agent)
      klass = asking("SpecRestoreFlow", agent: :spec_restore_agent)
      adapter = Smith::PersistenceAdapters::Memory.new
      workflow = klass.new(context: context)
      workflow.persist!("run-1", adapter:)
      restored = klass.restore("run-1", adapter:)
      server.reply(json: message("ok"))
      restored.run!

      expect(restored.to_state[:provider_credentials_scope]).to eq("project_id" => "proj_42")
      expect(block_calls).to eq([{ "project_id" => "proj_42" }])
      expect(keys_sent).to eq([canary])
    end

    # The saved scope decides, never the context a restore gives again.
    it "asks the block with the saved scope after a restore whose context names another value, or none" do
      agent("SpecSavedScopeAgent", register: :spec_saved_scope_agent)
      klass = asking("SpecSavedScopeFlow", agent: :spec_saved_scope_agent)
      adapter = Smith::PersistenceAdapters::Memory.new
      klass.new(context: context).persist!("run-1", adapter:)
      saved = JSON.parse(adapter.fetch("run-1"))
      changed = [saved["context"].merge("project_id" => "proj_other"), saved["context"].except("project_id")]
      changed.each_with_index do |given, index|
        adapter.store("run-#{index + 2}", JSON.generate(saved.merge("context" => given)))
        server.reply(json: message("ok"))
        klass.restore("run-#{index + 2}", adapter:).run!
      end

      expect(block_calls).to eq([{ "project_id" => "proj_42" }] * 2)
      expect(keys_sent).to eq([canary] * 2)
    end
  end

  describe "the requests" do
    it "go out on the run's key and endpoint only, and leave RubyLLM's global configuration as it was" do
      agent("SpecKeyAgent", register: :spec_key_agent)
      server.reply(json: message("ok"))
      run(asking("SpecKeyFlow", agent: :spec_key_agent))

      expect(keys_sent).to eq([canary])
      expect(RubyLLM.config.anthropic_api_key).to eq(global_key)
    end

    it "go out on a context that cleared every provider's secret and endpoint and kept every other setting" do
      RubyLLM.config.openai_use_system_role = true
      RubyLLM.config.gemini_api_key = global_key
      agent("SpecClearedAgent", register: :spec_cleared_agent)
      server.reply(json: message("ok"))
      workflow, = run(asking("SpecClearedFlow", agent: :spec_cleared_agent))
      config = workflow.instance_variable_get(:@smith_run_credentials).ruby_llm_config
      per_run = Smith::ProviderOptions::TABLE.flat_map do |provider, options|
        options.filter_map { |option, kind| :"#{provider}_#{option}" unless kind == :setting }
      end
      set = per_run.reject { config.public_send(_1).nil? }

      expect(set.sort).to eq(%i[anthropic_api_base anthropic_api_key openai_api_base openai_api_key])
      expect([config.openai_use_system_role, config.request_timeout, config.instrumenter])
        .to eq([true, RubyLLM.config.request_timeout, nil])
    ensure
      RubyLLM.config.gemini_api_key = nil
    end

    it "keep a global setting that is not a secret or an endpoint, such as openai_use_system_role" do
      RubyLLM.config.openai_use_system_role = true
      agent("SpecRoleAgent", register: :spec_role_agent, model: "gpt-5", provider: :openai) do
        instructions { |_context| "Classify the posting." }
      end
      server.reply(json: openai_message("ok"))
      run(asking("SpecRoleFlow", agent: :spec_role_agent))

      roles = server.requests.sole.body["messages"].map { _1["role"] }
      expect(roles.first).to eq("system")
      expect(keys_sent).to eq(["Bearer #{canary}"])
    end

    it "never send a global key for a provider the run's credentials do not cover: that candidate is skipped" do
      only_openai = Smith::ProviderCredentials.new(openai: { api_key: canary, api_base: "#{server.url}/v1" })
      agent("SpecSkipAgent", register: :spec_skip_agent, fallbacks: [{ model: "gpt-5", provider: :openai }])
      server.reply(json: openai_message("ok"))
      _workflow, result = run(asking("SpecSkipFlow", agent: :spec_skip_agent, returning: -> { only_openai }))

      expect(result.state).to eq(:done)
      expect(server.requests.map(&:path)).to eq(["/v1/chat/completions"])
      expect(keys_sent).to eq(["Bearer #{canary}"])
      expect(server.requests.map { _1.headers.values.join }.join).not_to include(global_key)
    end

    it "read an unqualified model's provider from RubyLLM's registry, and skip it when the credentials miss it" do
      only_openai = Smith::ProviderCredentials.new(openai: { api_key: canary, api_base: "#{server.url}/v1" })
      Smith::Agent::Registry.delete(:spec_registry_agent)
      with_stubbed_class("SpecRegistryAgent", Smith::Agent) do
        register_as :spec_registry_agent
        model "claude-sonnet-4-5"
        fallback_models({ model: "gpt-5", provider: :openai })
      end
      server.reply(json: openai_message("ok"))
      _workflow, result = run(asking("SpecRegistryFlow", agent: :spec_registry_agent, returning: -> { only_openai }))

      expect(result.state).to eq(:done)
      expect(server.requests.map(&:path)).to eq(["/v1/chat/completions"])
    end

    it "go out to a provider that needs no key (a local Ollama) with no key at all" do
      local = Smith::ProviderCredentials.new(ollama: { api_base: "#{server.url}/v1" })
      agent("SpecLocalAgent", register: :spec_local_agent, model: "llama3.2", provider: :ollama)
      server.reply(json: openai_message("ok", model: "llama3.2"))
      _workflow, result = run(asking("SpecLocalFlow", agent: :spec_local_agent, returning: -> { local }))

      expect(result.state).to eq(:done)
      expect(server.requests.map(&:path)).to eq(["/v1/chat/completions"])
      expect(keys_sent).to eq([nil])
    end

    # A host's gateway in RubyLLM's global configuration is another place
    # its own key could go: the run's requests go where its credentials say,
    # or to the provider's own endpoint.
    it "never go to a global endpoint the run's credentials do not name" do
      gateway = SseServer.new
      RubyLLM.config.anthropic_api_base = gateway.url
      urls = []
      allow_any_instance_of(Faraday::Adapter::NetHttp).to receive(:call).and_wrap_original do |original, env|
        urls << env.url.to_s
        raise Faraday::ConnectionFailed, "not sent" unless env.url.host == "127.0.0.1"

        original.call(env)
      end
      key_only = Smith::ProviderCredentials.new(anthropic: { api_key: canary })
      agent("SpecEndpointAgent", register: :spec_endpoint_agent)
      run(asking("SpecEndpointFlow", agent: :spec_endpoint_agent, returning: -> { key_only }))

      expect(gateway.requests).to eq([])
      expect(urls).to eq(["https://api.anthropic.com/v1/messages"])
    ensure
      gateway&.close
    end

    it "fail with the step's own error when a covered candidate fails and only uncovered ones are left" do
      only_anthropic = Smith::ProviderCredentials.new(anthropic: { api_key: canary, api_base: server.url })
      agent("SpecAloneAgent", register: :spec_alone_agent)
      agent("SpecLastCoveredAgent", register: :spec_last_covered_agent, fallbacks: ["openai/gpt-5"])
      errors = { "SpecLastAloneFlow" => :spec_alone_agent, "SpecLastCoveredFlow" => :spec_last_covered_agent }
               .map do |flow, name|
                 server.reply(json: anthropic_error("api_error", "upstream busy"), status: "500 Internal Server Error")
                 run(asking(flow, agent: name, returning: -> { only_anthropic })).last.last_error
               end

      expect(errors.map(&:class).uniq).to eq([errors.first.class])
      expect(errors.last).not_to be_a(Smith::WorkflowError)
      expect(errors.map(&:message).uniq).to eq([errors.first.message])
    end

    # A service account key is JSON; its windows would hold ordinary text
    # (https://www., googleapis.c), so only its secret parts are scrubbed.
    it "leave an error that holds no part of a key alone, a Vertex AI service account key among the credentials" do
      allow_any_instance_of(Faraday::Adapter::NetHttp).to receive(:call).and_wrap_original do |original, env|
        if env.url.host == "127.0.0.2"
          raise Faraday::ConnectionFailed, "Failed to open TCP connection to generativelanguage.googleapis.com:443 " \
                                           "(getaddrinfo: nodename nor servname provided, or not known)"
        end

        original.call(env)
      end
      account = JSON.generate("type" => "service_account", "project_id" => "cust-proj-1",
                              "private_key_id" => SecureRandom.hex(20),
                              "private_key" => "-----BEGIN PRIVATE KEY-----\n#{SecureRandom.base64(600)}\n" \
                                               "-----END PRIVATE KEY-----\n",
                              "client_email" => "evals@cust-proj-1.iam.gserviceaccount.com",
                              "token_uri" => "https://oauth2.googleapis.com/token",
                              "auth_provider_x509_cert_url" => "https://www.googleapis.com/oauth2/v1/certs")
      with_vertex = Smith::ProviderCredentials.new(
        gemini: { api_key: canary, api_base: "http://127.0.0.2:9/v1beta" },
        openai: { api_key: canary, api_base: "#{server.url}/v1" },
        vertexai: { project_id: "cust-proj-1", location: "us-central1", service_account_key: account }
      )
      agent("SpecGeminiAgent", register: :spec_gemini_agent, model: "gemini-2.5-flash", provider: :gemini,
                               fallbacks: [{ model: "gpt-5", provider: :openai }])
      server.reply(json: openai_message("ok"))
      _workflow, result = run(asking("SpecGeminiFlow", agent: :spec_gemini_agent, returning: -> { with_vertex }))

      expect(result.state).to eq(:done)
      expect(server.requests.map(&:path)).to eq(["/v1/chat/completions"])
    end

    it "are not made, nor any ledger asked, when the credentials cover none of an agent's models" do
      only_gemini = Smith::ProviderCredentials.new(gemini: { api_key: canary })
      ledger_calls = []
      agent("SpecNoneAgent", register: :spec_none_agent, fallbacks: [{ model: "gpt-5", provider: :openai }])
      klass = asking("SpecNoneFlow", agent: :spec_none_agent, returning: -> { only_gemini }) do
        budget_ledger { ledger_calls << :built }
      end
      _workflow, result = run(klass)

      expect(result.last_error).to be_a(Smith::ProviderCredentialsMissing)
      expect(result.last_error.message).to eq("the run's credentials cover none of anthropic, openai")
      expect(result.last_error.kind).to eq(:credentials_missing)
      expect([server.requests, ledger_calls]).to eq([[], []])
    end
  end

  describe "the block" do
    it "is called once per run per process, however many branches ask at once" do
      agent("SpecBranchAgent", register: :spec_branch_agent)
      server.answer { { json: message("ok") } }
      calls = block_calls
      given = credentials
      klass = with_stubbed_class("SpecBranchFlow", Smith::Workflow) do
        initial_state :idle
        state :failed
        provider_credentials(:project_id) do |scope|
          calls << scope
          sleep 0.05
          given
        end
        seed_messages { |_context| [{ role: :user, content: "classify" }] }
        transition :ask, from: :idle, to: :done do
          execute :spec_branch_agent, parallel: true, count: 16
          on_failure :fail
        end
      end
      Smith.config.parallel_concurrency = 16
      _workflow, result = run(klass)

      expect(result.state).to eq(:done)
      expect(server.requests.length).to eq(16)
      expect(keys_sent.uniq).to eq([canary])
      expect(block_calls).to eq([{ "project_id" => "proj_42" }])
    ensure
      Smith.config.parallel_concurrency = 8
    end

    it "fails the step with ProviderCredentialsMissing, before any request or ledger call, when it returns nil" do
      ledger_calls = []
      agent("SpecNilAgent", register: :spec_nil_agent, fallbacks: [{ model: "gpt-5", provider: :openai }])
      klass = asking("SpecNilFlow", agent: :spec_nil_agent, returning: -> {}) do
        budget_ledger do
          ledger_calls << :built
        end
      end
      _workflow, result = run(klass)

      expect(result.last_error).to be_a(Smith::ProviderCredentialsMissing)
      expect(result.last_error.message).to eq("the run's provider_credentials block returned no credentials")
      expect([server.requests, ledger_calls, block_calls.length]).to eq([[], [], 1])
    end

    it "fails the step with ProviderCredentialsError naming only the class when it raises, with nothing sent" do
      key = canary
      agent("SpecRaiseAgent", register: :spec_raise_agent, fallbacks: [{ model: "gpt-5", provider: :openai }])
      klass = asking("SpecRaiseFlow", agent: :spec_raise_agent, returning: -> { raise KeyError, "no key #{key}" })
      _workflow, result = run(klass)
      error = result.last_error

      expect(error).to be_a(Smith::ProviderCredentialsError)
      expect([error.message, error.cause]).to eq(["the provider_credentials block raised KeyError", nil])
      expect(server.requests).to eq([])
    end

    # Smith's own checks name options and fields, never values, so the host
    # is told what is wrong with the credentials its block built.
    it "fails the step with ProviderCredentialsError saying what Smith's check refused in what it built" do
      vertex = { project_id: "cust-proj-1", location: "us-central1" }
      agent("SpecCheckedAgent", register: :spec_checked_agent)
      klass = asking("SpecCheckedFlow", agent: :spec_checked_agent,
                                        returning: -> { Smith::ProviderCredentials.new(vertexai: vertex) })
      _workflow, result = run(klass)

      expect(result.last_error).to be_a(Smith::ProviderCredentialsError)
      expect(result.last_error.message).to eq(
        "the provider_credentials block's credentials were refused: vertexai's credentials need " \
        "service_account_key, the credential it sends, or RubyLLM would find one of its own"
      )
      expect([result.last_error.cause, server.requests]).to eq([nil, []])
    end

    it "fails the step with ProviderCredentialsError when it returns something else" do
      agent("SpecOddAgent", register: :spec_odd_agent)
      _workflow, result = run(asking("SpecOddFlow", agent: :spec_odd_agent, returning: -> { { anthropic: canary } }))

      expect(result.last_error).to be_a(Smith::ProviderCredentialsError)
      expect(result.last_error.message).to eq(
        "the provider_credentials block must return a Smith::ProviderCredentials or nil, not a Hash"
      )
      expect(server.requests).to eq([])
    end
  end

  describe "a provider that refuses the run's key" do
    it "gives ProviderCredentialsRefused for a 401 and tries that provider no more in the step" do
      agent("SpecRefusedAgent", register: :spec_refused_agent, fallbacks: ["anthropic/claude-haiku-5-5"])
      server.reply(json: anthropic_error("authentication_error", "invalid x-api-key"), status: "401 Unauthorized")
      _workflow, result = run(asking("SpecRefusedFlow", agent: :spec_refused_agent))
      error = result.last_error

      expect(error).to be_a(Smith::ProviderCredentialsRefused)
      expect([error.kind, error.status, error.provider]).to eq([:key_refused, 401, :anthropic])
      expect(error.message).to eq("anthropic refused the run's key (HTTP 401)")
      expect(server.requests.length).to eq(1)
    end

    it "keeps a refusal's and a missing key's class and kind in a restored run's failure" do
      agent("SpecKeptAgent", register: :spec_kept_agent)
      server.reply(json: anthropic_error("authentication_error", "invalid x-api-key"), status: "401 Unauthorized")
      refused, = run(asking("SpecKeptRefused", agent: :spec_kept_agent))
      missing, = run(asking("SpecKeptMissing", agent: :spec_kept_agent, returning: -> {}))
      restored = [refused, missing].map do |workflow|
        workflow.class.from_state(JSON.parse(JSON.generate(workflow.to_state))).run!.last_error
      end

      expect(restored.map(&:class)).to eq([Smith::ProviderCredentialsRefused, Smith::ProviderCredentialsMissing])
      expect(restored.map(&:kind)).to eq(%i[key_refused credentials_missing])
      expect(restored.map(&:message)).to eq(["anthropic refused the run's key (HTTP 401)",
                                             "the run's provider_credentials block returned no credentials"])
      expect([restored.first.status, restored.first.provider]).to eq([401, :anthropic])
    end

    it "asks the block again at the next step after a 401, so a rotated key is taken up" do
      agent("SpecRotatedAgent", register: :spec_rotated_agent, fallbacks: [{ model: "gpt-5", provider: :openai }])
      agent("SpecSecondAgent", register: :spec_second_agent)
      klass = asking("SpecRotatedFlow", agent: :spec_rotated_agent) do
        transition :ask, from: :idle, to: :asked do
          execute :spec_rotated_agent, output_to: :answer
          on_failure :fail
        end
        transition :again, from: :asked, to: :done do
          execute :spec_second_agent, output_to: :again
          on_failure :fail
        end
      end
      server.reply(json: anthropic_error("authentication_error", "invalid x-api-key"), status: "401 Unauthorized")
            .reply(json: openai_message("ok"))
            .reply(json: message("ok again"))
      _workflow, result = run(klass)

      expect(result.state).to eq(:done)
      expect(server.requests.map(&:path)).to eq(%w[/v1/messages /v1/chat/completions /v1/messages])
      expect(block_calls.length).to eq(2)
    end

    it "lets another model of the same provider run after a 403, and gives kind permission with none left" do
      agent("SpecForbiddenAgent", register: :spec_forbidden_agent, fallbacks: ["anthropic/claude-haiku-5-5"])
      server.reply(json: anthropic_error("permission_error", "no access"), status: "403 Forbidden")
            .reply(json: message("ok", model: "claude-haiku-5-5"))
      _workflow, result = run(asking("SpecForbiddenFlow", agent: :spec_forbidden_agent))

      expect(result.state).to eq(:done)
      expect(server.requests.map { _1.body["model"] }).to eq(%w[claude-sonnet-5-5 claude-haiku-5-5])

      server.reply(json: anthropic_error("permission_error", "no access"), status: "403 Forbidden")
            .reply(json: anthropic_error("permission_error", "no access"), status: "403 Forbidden")
      _workflow, result = run(asking("SpecForbiddenAll", agent: :spec_forbidden_agent))
      expect([result.last_error.class, result.last_error.kind]).to eq([Smith::ProviderCredentialsRefused, :permission])
      expect(result.last_error.message).to eq("anthropic refused the run's key access to this model (HTTP 403)")
      expect(block_calls.length).to eq(2)
    end

    it "keeps a 402's class path with Smith's fixed message, and interrupts when it is a listed interrupting error" do
      agent("SpecCreditAgent", register: :spec_credit_agent)
      body = anthropic_error("billing_error", "Your credit balance is too low (#{canary})")
      server.reply(json: body, status: "402 Payment Required")
      _workflow, result = run(asking("SpecCreditFlow", agent: :spec_credit_agent))
      error = result.last_error

      expect(error.class).to eq(Smith::ProviderPermanentFailure)
      expect(error.message).to eq("anthropic reports the account is out of credit (HTTP 402)")
      expect([error.cause.class, error.cause.message]).to eq(
        [RubyLLM::PaymentRequiredError, "the provider reports the account is out of credit (HTTP 402)"]
      )

      Smith.config.interrupting_errors = [RubyLLM::PaymentRequiredError]
      server.reply(json: body, status: "402 Payment Required")
      workflow = asking("SpecCreditWaits", agent: :spec_credit_agent).new(context: context)
      expect { workflow.run! }.to raise_error(RubyLLM::PaymentRequiredError) { |raised|
        expect([raised.message, raised.cause]).to eq(["the provider reports the account is out of credit (HTTP 402)",
                                                      nil])
      }
      expect(workflow.state).to eq(:idle)
    end
  end

  describe "an error raised inside a credentialed attempt" do
    def failing_tool(error)
      Class.new(Smith::Tool) do
        def self.name = "SpecFailingTool"
        description "Looks a place up."
        param :query, type: :string, required: true
        define_method(:perform) { |query:| raise error unless query.empty? }
      end
    end

    def tool_call
      call = { "type" => "tool_use", "id" => "toolu_1", "name" => "spec_failing", "input" => { "query" => "x" } }
      { "id" => "msg_t", "type" => "message", "role" => "assistant", "model" => "claude-sonnet-5-5",
        "content" => [call], "stop_reason" => "tool_use", "usage" => { "input_tokens" => 10, "output_tokens" => 2 } }
    end

    def chain(error) = [error, *(error.cause && chain(error.cause))]

    def raised_in_tool(message, raised: ArgumentError.new(message), returning: -> { credentials })
      tool = failing_tool(raised)
      agent("SpecToolAgent", register: :spec_tool_agent) { tools tool }
      server.reply(json: tool_call)
      _workflow, result = run(asking("SpecToolFlow", agent: :spec_tool_agent, returning:))
      [raised, chain(result.last_error)]
    end

    def held(errors) = errors.select { "#{_1.message} #{_1.inspect}".include?(canary[10, 12]) }

    it "is raised as Smith::ScrubbedError naming its class, with no cause, when its text held the key" do
      _raised, errors = raised_in_tool("lookup failed for #{canary}")
      scrubbed = errors.find { _1.is_a?(Smith::ScrubbedError) }

      expect([scrubbed&.original_class, scrubbed&.cause]).to eq(["ArgumentError", nil])
      expect(errors.map(&:message).join).not_to include(canary[10, 12])
    end

    it "is raised as the very same object when its text held no part of the key" do
      raised, errors = raised_in_tool("lookup failed")

      expect(errors).to include(be_equal(raised))
      expect(errors.grep(Smith::ScrubbedError)).to eq([])
    end

    it "is raised as Smith::ScrubbedError when only how it prints holds the key" do
      key = canary
      printing = Class.new(StandardError) { define_method(:inspect) { "#<SpecPrintingError key=#{key}>" } }
      _raised, errors = raised_in_tool("lookup failed", raised: printing.new("lookup failed"))

      expect(errors.grep(Smith::ScrubbedError).map(&:cause)).to eq([nil])
      expect(held(errors)).to eq([])
    end

    it "is raised as Smith::ScrubbedError, with no cause, when only its cause holds the key" do
      wrapped = begin
        begin
          raise KeyError, "no entry for #{canary}"
        rescue KeyError
          raise ArgumentError, "lookup failed"
        end
      rescue ArgumentError => e
        e
      end
      _raised, errors = raised_in_tool("lookup failed", raised: wrapped)

      expect(errors.grep(Smith::ScrubbedError).map { [_1.original_class, _1.cause] }).to eq([["ArgumentError", nil]])
      expect(held(errors)).to eq([])
    end

    it "leaves an error with an address in it alone, a Vertex AI service account key among the credentials" do
      account = JSON.generate("type" => "service_account", "project_id" => "cust-proj-1",
                              "private_key_id" => SecureRandom.hex(20),
                              "private_key" => "-----BEGIN PRIVATE KEY-----\n#{SecureRandom.base64(600)}\n" \
                                               "-----END PRIVATE KEY-----\n",
                              "client_email" => "evals@cust-proj-1.iam.gserviceaccount.com",
                              "auth_provider_x509_cert_url" => "https://www.googleapis.com/oauth2/v1/certs")
      with_vertex = Smith::ProviderCredentials.new(
        anthropic: { api_key: canary, api_base: server.url },
        vertexai: { project_id: "cust-proj-1", location: "us-central1", service_account_key: account }
      )
      raised, errors = raised_in_tool("could not fetch https://www.example.com/jobs/42 (HTTP 503)",
                                      returning: -> { with_vertex })

      expect(errors).to include(be_equal(raised))
      expect(errors.grep(Smith::ScrubbedError)).to eq([])
    end

    # A scrub that fails (a bug in it) must not raise with the original,
    # which may hold the key, as its cause.
    it "is raised as Smith::ScrubbedError naming its class, with no cause, when the scrub itself fails" do
      agent("SpecScrubFailsAgent", register: :spec_scrub_fails_agent)
      server.reply(json: anthropic_error("api_error", "upstream said #{canary} was odd"),
                   status: "500 Internal Server Error")
      allow(Smith::ProviderOptions).to receive(:copy).and_raise(NoMethodError, "the copy failed")
      _workflow, result = run(asking("SpecScrubFailsFlow", agent: :spec_scrub_fails_agent))
      errors = chain(result.last_error)

      expect(errors.grep(Smith::ScrubbedError).map { [_1.original_class, _1.cause] })
        .to eq([["RubyLLM::ServerError", nil]])
      expect(held(errors)).to eq([])
    end

    # Ruby makes what was being handled the cause of anything raised while
    # it is: the scrubbed error is what is handled, never the original.
    it "gives nothing raised while a failure is handled a cause that holds the key or its request" do
      tool = Class.new(Smith::Tool) do
        def self.name = "SpecPassingTool"
        description "Looks a place up."
        param :query, type: :string, required: true
        define_method(:perform) { |query:| "found #{query}" }
      end
      agent("SpecPrefixAgent", register: :spec_prefix_agent) { tools tool }
      call = { "type" => "tool_use", "id" => "toolu_1", "name" => "spec_passing", "input" => { "query" => "x" } }
      server.reply(json: tool_call.merge("content" => [call]))
            .reply(json: anthropic_error("api_error", "upstream said #{canary} was odd"),
                   status: "500 Internal Server Error")
      allow(Smith::Pricing).to receive(:compute_cost).and_raise(RuntimeError, "pricing catalog unavailable")
      _workflow, result = run(asking("SpecPrefixFlow", agent: :spec_prefix_agent))
      errors = chain(result.last_error)
      requests = errors.grep(RubyLLM::Error).filter_map do |error|
        error.response.env&.request_headers if error.response.respond_to?(:env)
      end

      expect(errors.map(&:class)).to include(RuntimeError, RubyLLM::ServerError)
      expect(held(errors)).to eq([])
      expect(requests.map { _1.to_h.values.join }.join).not_to include(canary)
    end
  end

  describe "an image agent's paint" do
    let(:drawn) { "\x89PNG\r\n\x1A\n".b + "drawn".b }
    let(:painted) do
      { "created" => 1, "data" => [{ "b64_json" => [drawn].pack("m0") }],
        "usage" => { "input_tokens" => 40, "output_tokens" => 823, "total_tokens" => 863 } }
    end

    before do
      agent("SpecPainter", register: :spec_painter, model: "gpt-image-test", provider: :openai) do
        image size: "1024x1024", quality: "low"
      end
    end

    def chain(error) = error ? [error, *chain(error.cause)] : []

    it "gives nothing raised while its failure is handled a cause that holds the key" do
      allow_any_instance_of(Smith::Workflow).to receive(:record_billed_usages)
        .and_raise(RuntimeError, "usage store unavailable")
      server.reply(json: { "error" => { "message" => "upstream echoed #{canary}", "type" => "server_error" } },
                   status: "500 Internal Server Error")
      _workflow, result = run(asking("SpecPaintHandled", agent: :spec_painter))
      errors = chain(result.last_error)

      expect(errors.map(&:class)).to include(RuntimeError)
      expect(errors.select { "#{_1.message} #{_1.inspect}".include?(canary[10, 12]) }).to eq([])
    end

    it "records a billed image it could not keep, then raises the store's error scrubbed, with no cause" do
      key = canary
      store = Class.new { define_method(:store) { |*, **| raise IOError, "bucket refused #{key}" } }.new
      allow(Smith).to receive(:artifacts).and_return(store)
      server.reply(json: painted)
      workflow, result = run(asking("SpecPaintUnkept", agent: :spec_painter))
      errors = chain(result.last_error)
      scrubbed = errors.grep(Smith::ScrubbedError)

      expect(scrubbed.map { [_1.original_class, _1.cause] }).to eq([["IOError", nil]])
      expect(workflow.usage_entries.map(&:attempt_kind)).to eq([:partial_attempt])
      expect(errors.map { "#{_1.message} #{_1.inspect}" }.join).not_to include(canary[10, 12])
    end
  end

  describe "a batch step" do
    let(:queue) do
      Class.new do
        attr_reader :items

        def initialize = @items = []
        def enqueue(**request) = @items << request
      end.new
    end

    around do |example|
      saved = Smith.config.batch_queue
      Smith.config.batch_queue = queue
      example.run
    ensure
      Smith.config.batch_queue = saved
    end

    def batching(name, credentialed: true, &body)
      asking(name, agent: :spec_batch_agent, credentialed:) do
        transition :ask, from: :idle, to: :done do
          execute :spec_batch_agent, output_to: :answer, mode: :batch, on_request_change: :fail
          on_failure :fail
        end
        class_exec(&body) if body
      end
    end

    def deliver(workflow, message)
      token = workflow.awaiting.token
      items = queue.items.select { _1[:await_token] == token }
      workflow.resume!(event: :batch_result, token:,
                       payload: items.to_h { [_1[:custom_id], { "type" => "succeeded", "message" => message }] })
    end

    # Reading a result's usage sends nothing, so it needs no key, and a
    # worker serving many accounts' keys keeps none in RubyLLM's global
    # configuration.
    it "reads a result it sets aside in a worker with no key in RubyLLM's global configuration" do
      day = +"Monday"
      Smith::Agent::Registry.delete(:spec_batch_agent)
      with_stubbed_class("SpecBatchAgent", Smith::Agent) do
        register_as :spec_batch_agent
        model "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true
        instructions { "Today is #{day}." }
      end
      RubyLLM.config.anthropic_api_key = nil
      RubyLLM.config.openai_api_key = nil
      workflow = batching("SpecBatchUnkeyed").new(context: context)
      workflow.run!
      day.replace("Tuesday")

      expect(deliver(workflow, message("Monday, from the batch", tokens: [5, 2]))).to eq(:failed)
      expect(workflow.to_state[:last_failed_step]).to include(error_class: "Smith::BatchRequestChanged")
      expect(workflow.usage_entries.map { [_1.mode, _1.attempt_kind, _1.input_tokens] })
        .to eq([[:batch, :failed_attempt, 5]])
    end

    it "hands the queue a credentialed run's scope, so the host submits it on that scope's key, and no key" do
      agent("SpecBatchAgent", register: :spec_batch_agent)
      batching("SpecBatchScoped").new(context: context).run!
      batching("SpecBatchPlain", credentialed: false).new(context: context).run!

      expect(queue.items.map { _1.except(:custom_id, :await_token, :request, :execution_key) })
        .to eq([{ credentials_scope: { "project_id" => "proj_42" } }, {}])
      expect(queue.items.map(&:inspect).join).not_to include(canary)
    end

    # The submitter's configuration is the run's, as a run's context is: no
    # global key, endpoint (a host's gateway) or instrumenter kept.
    it "submits on the credentials alone, never RubyLLM's global endpoint or instrumenter" do
      require "smith/providers/anthropic/batches"
      gateway = SseServer.new
      seen = []
      RubyLLM.config.anthropic_api_base = gateway.url
      RubyLLM.config.instrumenter = Class.new do
        define_method(:instrument) { |name, payload = {}, &block| (seen << name) && block&.call(payload) }
      end.new
      urls = []
      allow_any_instance_of(Faraday::Adapter::NetHttp).to receive(:call).and_wrap_original do |original, env|
        urls << env.url.to_s
        raise Faraday::ConnectionFailed, "not sent" unless env.url.host == "127.0.0.1"

        original.call(env)
      end
      key_only = Smith::ProviderCredentials.new(anthropic: { api_key: canary })
      expect { Smith::Providers::Anthropic::Batches.new(credentials: key_only).status("msgbatch_1") }
        .to raise_error(Faraday::ConnectionFailed)

      expect(urls).to eq(["https://api.anthropic.com/v1/messages/batches/msgbatch_1"])
      expect([gateway.requests, seen]).to eq([[], []])
    ensure
      gateway&.close
    end

    it "submits on the credentials it is given, never RubyLLM's global key, which the fail-closed mode refuses" do
      require "smith/providers/anthropic/batches"
      server.reply(json: { "id" => "msgbatch_1", "processing_status" => "in_progress" })
      batches = Smith::Providers::Anthropic::Batches.new(credentials:)
      batches.status("msgbatch_1")

      expect(keys_sent).to eq([canary])
      expect([batches.inspect, batches.pretty_inspect].join).not_to include(canary[10, 12])
      expect { Smith::Providers::Anthropic::Batches.new(credentials: Smith::ProviderCredentials.new(openai: { api_key: canary })) }
        .to raise_error(Smith::ProviderCredentialsMissing, /anthropic/)
      Smith.config.require_run_credentials = true
      expect { Smith::Providers::Anthropic::Batches.new }.to raise_error(Smith::ProviderCredentialsMissing)
      expect(server.requests.length).to eq(1)
    end
  end

  describe "nested items" do
    # An item is data, possibly a model's output: it must not choose whose
    # keys a nested run uses.
    it "refuse an item's key as the scope of a nested class's own credentials, before anything is sent" do
      agent("SpecItemAgent", register: :spec_item_agent)
      room = asking("SpecItemRoom", agent: :spec_item_agent, scope: [:room])
      klass = asking("SpecItemRooms", agent: :spec_item_agent) do
        transition :ask, from: :idle, to: :done do
          workflow room, over: ->(context) { context[:rooms] }, item_to: :room, concurrency: 1, output_to: :rooms
          on_failure :fail
        end
      end
      result = klass.new(context: context.merge(rooms: %w[kitchen])).run!

      expect(result.last_error).to be_a(Smith::WorkflowError)
      expect(result.last_error.message).to match(/item_to/)
      expect([server.requests, block_calls]).to eq([[], []])
      expect(klass.runtime_readiness.runtime_diagnostics.map { [_1.code, _1.severity] })
        .to include(%i[item_chooses_run_credentials error])
    end
  end
end
