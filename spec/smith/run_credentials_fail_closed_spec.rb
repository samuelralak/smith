# frozen_string_literal: true

require "active_support"
require "active_support/logger"
require "fileutils"
require "stringio"
require "tmpdir"
require "smith/doctor"
require "smith/provider_options"

# The fail-closed mode (additions design 3.4, S4): with
# Smith.config.require_run_credentials on, a provider attempt in no run with
# run credentials fails before anything is sent or any budget ledger asked,
# and readiness and the doctor say what would let a key fall through.
RSpec.describe "Run credentials, fail-closed" do
  include_context "with run credentials"

  let(:context) { { project_id: "proj_42" } }
  let(:ledger_calls) { [] }

  def codes(klass) = klass.runtime_readiness.runtime_diagnostics.map { [_1.code, _1.severity] }

  # Every provider's secret in RubyLLM's global configuration, which another
  # spec may have left set; put back after each example.
  let(:secrets) do
    Smith::ProviderOptions::TABLE.flat_map do |provider, options|
      options.filter_map { |option, kind| :"#{provider}_#{option}" if kind == :secret }
    end
  end

  # Where a cloud SDK finds credentials of its own (all fake here): none
  # unless an example plants them, whatever the machine running this holds.
  let(:ambient_env) do
    %w[GOOGLE_APPLICATION_CREDENTIALS CLOUDSDK_CONFIG AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
       AWS_PROFILE AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN
       AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AZURE_CLIENT_ID AZURE_CLIENT_SECRET
       AZURE_TENANT_ID AZURE_CLIENT_CERTIFICATE_PATH AZURE_FEDERATED_TOKEN_FILE AZURE_USERNAME AZURE_PASSWORD
       GOOGLE_PRIVATE_KEY GOOGLE_CLIENT_EMAIL GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_REFRESH_TOKEN]
  end

  around do |example|
    kept = secrets.to_h { [_1, RubyLLM.config.public_send(_1)] }
    logger = RubyLLM.config.logger
    env = (ambient_env + ["HOME"]).to_h { [_1, ENV.fetch(_1, nil)] }
    Dir.mktmpdir do |home|
      ambient_env.each { ENV.delete(_1) }
      ENV["HOME"] = home
      example.run
    end
  ensure
    kept.each { |option, value| RubyLLM.config.public_send(:"#{option}=", value) }
    RubyLLM.config.logger = logger
    env.each { |name, value| ENV[name] = value }
  end

  def clear_global_keys! = secrets.each { RubyLLM.config.public_send(:"#{_1}=", nil) }

  def counting_ledger
    calls = ledger_calls
    Class.new do
      define_method(:reserve!) { |*| (calls << :reserve) && true }
      define_method(:reconcile!) { |*| calls << :reconcile }
      define_method(:release!) { |*| calls << :release }
    end.new
  end

  before { agent("SpecClosedAgent", register: :spec_closed_agent) }

  it "fails an undeclared class's step with ProviderCredentialsMissing, before any request or ledger call" do
    Smith.config.require_run_credentials = true
    ledger = counting_ledger
    built = ledger_calls
    klass = asking("SpecUndeclaredFlow", agent: :spec_closed_agent, credentialed: false) do
      budget_ledger do
        built << :built
        ledger
      end
    end
    result = klass.new(context: context).run!

    expect(result.last_error).to be_a(Smith::ProviderCredentialsMissing)
    expect(result.last_error.message).to match(/require_run_credentials refuses/)
    expect([server.requests, ledger_calls]).to eq([[], []])
  end

  it "fails a workflow started by hand inside a credentialed run's step, before any request or ledger call" do
    Smith.config.require_run_credentials = true
    inner = asking("SpecByHandFlow", agent: :spec_closed_agent, credentialed: false)
    raised = []
    outer = asking("SpecOuterFlow", agent: :spec_closed_agent) do
      transition :ask, from: :idle, to: :done do
        compute do |_context|
          raised << inner.new(context: {}).run!.last_error
          {}
        end
        on_failure :fail
      end
    end
    result = outer.new(context: context).run!

    expect(result.state).to eq(:done)
    expect(raised.map(&:class)).to eq([Smith::ProviderCredentialsMissing])
    expect([server.requests, block_calls]).to eq([[], []])
  end

  it "fails an undeclared child run's step, and lets a declared one run on the scope its input gives it" do
    Smith.config.require_run_credentials = true
    Smith.config.run_launcher = Smith::Launchers::Inline.new
    undeclared = asking("SpecUndeclaredChild", agent: :spec_closed_agent, credentialed: false)
    declared = asking("SpecDeclaredChild", agent: :spec_closed_agent)
    parent = lambda do |name, child|
      asking(name, agent: :spec_closed_agent) do
        transition :ask, from: :idle, to: :done do
          call child, input: ->(context) { { project_id: context[:project_id] } }, timeout: 60, into: :child
          on_failure :fail
        end
      end
    end

    failed = parent.call("SpecParentOfUndeclared", undeclared).new(context: context).run!
    expect(server.requests).to eq([])
    expect(failed.state).to eq(:failed)

    server.reply(json: message("ok"))
    done = parent.call("SpecParentOfDeclared", declared).new(context: context).run!
    expect(done.state).to eq(:done)
    expect(keys_sent).to eq([canary])
    expect(block_calls).to eq([{ "project_id" => "proj_42" }])
  end

  it "lets a nested workflow without its own declaration send on its parent's credentials, never the global ones" do
    Smith.config.require_run_credentials = true
    child = asking("SpecNestedChild", agent: :spec_closed_agent, credentialed: false)
    parent = asking("SpecNestingParent", agent: :spec_closed_agent) do
      transition :ask, from: :idle, to: :done do
        workflow child
        on_failure :fail
      end
    end
    server.reply(json: message("ok"))

    expect(parent.new(context: context).run!.state).to eq(:done)
    expect(keys_sent).to eq([canary])
    expect(server.requests.map { _1.headers.values.join }.join).not_to include(global_key)
  end

  it "makes readiness :not_ready for a class without provider_credentials, and for RubyLLM at DEBUG" do
    undeclared = asking("SpecReadyUndeclared", agent: :spec_closed_agent, credentialed: false)
    declared = asking("SpecReadyDeclared", agent: :spec_closed_agent)
    expect([undeclared.runtime_readiness.status, declared.runtime_readiness.status]).to eq(%i[ready ready])

    Smith.config.require_run_credentials = true
    clear_global_keys!
    expect(undeclared.runtime_readiness.status).to eq(:not_ready)
    expect(codes(undeclared)).to eq([%i[run_credentials_required error]])
    expect(declared.runtime_readiness.status).to eq(:ready)

    RubyLLM.config.log_level = Logger::DEBUG
    expect(declared.runtime_readiness.status).to eq(:not_ready)
    expect(codes(declared)).to eq([%i[debug_logging_with_run_credentials error]])
    RubyLLM.config.log_level = Logger::INFO
    RubyLLM.config.log_stream_debug = true
    expect(codes(declared)).to eq([%i[debug_logging_with_run_credentials error]])
  end

  # RubyLLM logs with config.logger when one is set (a Rails host sets
  # Rails.logger), else a Logger at config.log_level, which Logger takes as
  # an Integer, Symbol or String; once used, the logger it built is kept.
  it "reads RubyLLM's logger at DEBUG in every form it takes, and says which" do
    declared = asking("SpecReadyForms", agent: :spec_closed_agent)
    Smith.config.require_run_credentials = true
    clear_global_keys!
    io = StringIO.new
    rails = ActiveSupport::BroadcastLogger.new(ActiveSupport::Logger.new(io))
    forms = [["config.logger", -> { RubyLLM.config.logger = Logger.new(io, level: :debug) }],
             ["config.logger", -> { RubyLLM.config.logger = rails }],
             ["config.log_level :debug", -> { RubyLLM.config.log_level = :debug }],
             ["config.log_level \"DEBUG\"", -> { RubyLLM.config.log_level = "DEBUG" }],
             ["config.log_level 0", -> { RubyLLM.config.log_level = Logger::DEBUG }]]
    expect(declared.runtime_readiness.status).to eq(:ready)

    forms.each do |named, set|
      set.call
      diagnostic = declared.runtime_readiness.runtime_diagnostics.sole
      expect([diagnostic.code, diagnostic.severity]).to eq(%i[debug_logging_with_run_credentials error]), named
      expect(diagnostic.message).to include(named), named
      RubyLLM.config.logger = nil
      RubyLLM.config.log_level = Logger::INFO
    end
  end

  it "reads the logger RubyLLM already logs with, kept from its first use" do
    declared = asking("SpecReadyKeptLogger", agent: :spec_closed_agent)
    Smith.config.require_run_credentials = true
    clear_global_keys!
    kept = RubyLLM.instance_variable_get(:@logger)
    RubyLLM.instance_variable_set(:@logger, Logger.new(StringIO.new, level: :debug))

    expect(declared.runtime_readiness.runtime_diagnostics.map { [_1.code, _1.message] })
      .to match([[:debug_logging_with_run_credentials, /the logger RubyLLM logs with/]])
  ensure
    RubyLLM.instance_variable_set(:@logger, kept)
  end

  # RubyLLM 1.16.0 finds no credential of its own once a run names every
  # provider's (Smith requires it); a host's own RubyLLM or cloud SDK calls,
  # outside Smith's agents, could still use these.
  it "warns of credentials a cloud SDK would find in the environment or on the machine, by name only" do
    declared = asking("SpecReadyAmbient", agent: :spec_closed_agent)
    Smith.config.require_run_credentials = true
    clear_global_keys!
    expect(codes(declared)).to eq([])

    ENV["GOOGLE_APPLICATION_CREDENTIALS"] = File.join(Dir.home, "adc-ambient-0123456789abcdef.json")
    ENV["AWS_SECRET_ACCESS_KEY"] = "ambient-0123456789abcdef0123456789abcdef"
    ENV["GOOGLE_REFRESH_TOKEN"] = "ambient-0123456789abcdef0123456789abcdef"
    FileUtils.mkdir_p(File.join(Dir.home, ".aws"))
    File.write(File.join(Dir.home, ".aws", "credentials"), "[default]\naws_access_key_id = ambient\n")
    # gcloud's own login, which googleauth runs gcloud on for a key without its project.
    FileUtils.mkdir_p(File.join(Dir.home, ".config", "gcloud"))
    File.write(File.join(Dir.home, ".config", "gcloud", "credentials.db"), "ambient")
    diagnostic = declared.runtime_readiness.runtime_diagnostics.sole

    expect([diagnostic.code, diagnostic.severity]).to eq(%i[ambient_provider_credentials_present warning])
    expect(diagnostic.message).to include("GOOGLE_APPLICATION_CREDENTIALS", "AWS_SECRET_ACCESS_KEY",
                                          "GOOGLE_REFRESH_TOKEN", "~/.aws/credentials",
                                          "~/.config/gcloud/credentials.db")
    expect(diagnostic.message).not_to include("ambient-0123", "adc-ambient")
  end

  # Ruled 2026-11-23 (round 4): the mode refuses provider requests, so a
  # class whose steps ask no agent, itself or through a nested workflow on
  # its credentials (an abstract base, a compute-only workflow), needs none.
  it "keeps a class that asks no agent ready, an abstract base or a compute-only workflow" do
    base = with_stubbed_class("SpecReadyBase", Smith::Workflow)
    computing = with_stubbed_class("SpecReadyComputing", Smith::Workflow) do
      initial_state :idle
      state :done
      transition(:sum, from: :idle, to: :done) { compute { |_context| {} } }
    end
    nesting = lambda do |name, nested|
      with_stubbed_class(name, Smith::Workflow) do
        initial_state :idle
        state :done
        transition(:nest, from: :idle, to: :done) { workflow nested }
      end
    end
    asking_child = asking("SpecReadyAskingChild", agent: :spec_closed_agent, credentialed: false)
    Smith.config.require_run_credentials = true
    clear_global_keys!

    # The base is not ready for a reason of its own (no initial state).
    expect(base.runtime_readiness.diagnostics.map(&:code)).not_to include(:run_credentials_required)
    expect([computing.runtime_readiness.status, codes(computing)]).to eq([:ready, []])
    expect(codes(nesting.call("SpecReadyNestsComputing", computing))).to eq([])
    expect(codes(nesting.call("SpecReadyNestsAgent", asking_child))).to eq([%i[run_credentials_required error]])
  end

  # Ruled 2026-11-23 (round 4): a child run is a run of its own, so each child
  # class is judged on its own, never its parent by it.
  it "keeps a parent ready for its nested class and its child run's class, each judged on its own" do
    child = asking("SpecReadyNestedChild", agent: :spec_closed_agent, credentialed: false)
    nesting = asking("SpecReadyNesting", agent: :spec_closed_agent) do
      transition :ask, from: :idle, to: :done do
        workflow child
        on_failure :fail
      end
    end
    calling = asking("SpecReadyCalling", agent: :spec_closed_agent) do
      transition :ask, from: :idle, to: :done do
        call child, input: ->(context) { { project_id: context[:project_id] } }, timeout: 60, into: :child
        on_failure :fail
      end
    end
    Smith.config.run_launcher = Smith::Launchers::Inline.new
    Smith.config.require_run_credentials = true
    clear_global_keys!

    # A nested workflow runs in process, on its parent's credentials; a child
    # run is a run of its own, which a launcher may start anywhere.
    expect(nesting.runtime_readiness.status).to eq(:ready)
    expect(codes(nesting)).to eq([])
    expect(child.runtime_readiness.status).to eq(:not_ready)
    expect([calling.runtime_readiness.status, codes(calling)]).to eq([:ready, []])
    Smith.config.require_run_credentials = false
    expect(codes(calling)).to eq([])
  end

  it "warns of a key left in RubyLLM's global configuration, and of RubyLLM at DEBUG without the mode" do
    declared = asking("SpecReadyKeys", agent: :spec_closed_agent)
    Smith.config.require_run_credentials = true
    expect(codes(declared)).to eq([%i[global_provider_keys_present warning]])

    Smith.config.require_run_credentials = false
    RubyLLM.config.log_level = Logger::DEBUG
    expect(codes(declared)).to eq([%i[debug_logging_with_run_credentials warning]])
    expect(codes(asking("SpecReadyPlain", agent: :spec_closed_agent, credentialed: false))).to eq([])
  end

  it "refuses run_credentials_instrumenter :keep with the mode on, set in either order, and warns of it without" do
    Smith.config.require_run_credentials = true
    expect { Smith.config.run_credentials_instrumenter = :keep }.to raise_error(ArgumentError, /refused/)
    Smith.config.require_run_credentials = false
    Smith.config.run_credentials_instrumenter = :keep
    expect { Smith.config.require_run_credentials = true }.to raise_error(ArgumentError, /refuses/)
    expect(Smith.config.require_run_credentials).to be(false)

    declared = asking("SpecReadyKeep", agent: :spec_closed_agent)
    expect(codes(declared)).to eq([%i[instrumenter_with_run_credentials warning]])
    expect { Smith.config.run_credentials_instrumenter = :on }.to raise_error(ArgumentError, /:off or :keep/)
    expect { Smith.config.require_run_credentials = "yes" }.to raise_error(ArgumentError, /true or false/)
  end

  it "refuses an agent that would replace the run's context, in readiness and before any request" do
    agent("SpecContextAgent", register: :spec_context_agent) { context RubyLLM.context }
    agent("SpecInputAgent", register: :spec_input_agent) { inputs :context }
    %i[spec_context_agent spec_input_agent].each do |name|
      klass = asking("SpecRefused#{name.to_s.split("_")[1].capitalize}Flow", agent: name)
      result = klass.new(context: context).run!

      expect(codes(klass)).to eq([%i[agent_context_with_run_credentials error]])
      expect(result.last_error).to be_a(Smith::WorkflowError)
      expect(result.last_error.message).to match(/context/)
    end
    expect(server.requests).to eq([])
  end

  describe "the doctor" do
    def doctor
      report = Smith::Doctor.run(io: StringIO.new)
      report.checks.select { _1.name.start_with?("run_credentials.") }.to_h { [_1.name, _1.status] }
    end

    def checked = %w[run_credentials.logging run_credentials.global_keys run_credentials.ambient_credentials]

    it "checks nothing new without the mode, and with it, RubyLLM's logging, global keys and ambient ones" do
      expect(doctor).to eq({})

      Smith.config.require_run_credentials = true
      expect(doctor.slice(*checked)).to eq("run_credentials.logging" => :pass, "run_credentials.global_keys" => :warn,
                                           "run_credentials.ambient_credentials" => :pass)
      RubyLLM.config.log_level = :debug
      clear_global_keys!
      ENV["AWS_ACCESS_KEY_ID"] = "AKIAAMBIENT0123456789"
      expect(doctor.slice(*checked)).to eq("run_credentials.logging" => :fail, "run_credentials.global_keys" => :pass,
                                           "run_credentials.ambient_credentials" => :warn)
    end

    it "says why RubyLLM logs bodies, for a host logger at DEBUG too" do
      Smith.config.require_run_credentials = true
      RubyLLM.config.logger = Logger.new(StringIO.new, level: Logger::DEBUG)
      check = Smith::Doctor.run(io: StringIO.new).checks.find { _1.name == "run_credentials.logging" }

      expect([check.status, check.message]).to match([:fail, /config.logger/])
    end

    # Design 3.4: a class that declares none is refused under the mode. The
    # doctor sees the classes loaded when it runs; one used only as a nested
    # workflow of a credentialed class sends on its parent's.
    it "names each loaded workflow class that declares no provider_credentials and asks an agent" do
      with_stubbed_class("SpecDoctorBase", Smith::Workflow)
      with_stubbed_class("SpecDoctorComputing", Smith::Workflow) do
        initial_state :idle
        state :done
        transition(:sum, from: :idle, to: :done) { compute { |_context| {} } }
      end
      undeclared = asking("SpecDoctorUndeclared", agent: :spec_closed_agent, credentialed: false)
      nested = asking("SpecDoctorNestedOnly", agent: :spec_closed_agent, credentialed: false)
      asking("SpecDoctorDeclared", agent: :spec_closed_agent) do
        transition :ask, from: :idle, to: :done do
          workflow nested
          on_failure :fail
        end
      end
      Smith.config.require_run_credentials = true
      check = Smith::Doctor.run(io: StringIO.new).checks.find { _1.name == "run_credentials.workflow_classes" }

      expect([check.status, check.message]).to match([:fail, /declare no provider_credentials/])
      expect(check.detail).to start_with("Their provider requests are refused:")
      expect(check.detail).to include(undeclared.name)
      expect(check.detail).not_to include("SpecDoctorDeclared", "SpecDoctorNestedOnly", "SpecDoctorBase",
                                          "SpecDoctorComputing")
    end
  end
end
