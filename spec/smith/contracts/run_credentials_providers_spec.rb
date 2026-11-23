# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require "smith/provider_credentials"

# Every provider RubyLLM registers, under run credentials, with credentials
# planted (fake ones) wherever a provider library finds its own: the
# environment, the files cloud SDKs read, RubyLLM's global configuration
# (keys and endpoints), and Google's application default credentials
# (googleauth stood in for by spec/fixtures/googleauth). A run sends only
# what its Smith::ProviderCredentials hold, and the fail-closed mode refuses
# before anything is sent. The upgrade gate for RubyLLM (additions design
# 3.6): a provider that grows a fallback of its own fails here.
RSpec.describe "RubyLLM contract: a run sends only its own credentials, on every provider" do
  include_context "with run credentials"

  let(:context) { { project_id: "proj_42" } }
  let(:ambient) { "ambient-#{SecureRandom.hex(12)}" }
  let(:elsewhere) { SseServer.new }
  let(:key_id) { SecureRandom.hex(8).upcase }
  let(:account_id) { SecureRandom.hex(20) }
  let(:stand_in) { File.expand_path("../../fixtures/googleauth", __dir__) }
  let(:providers) { RubyLLM::Provider.providers.keys }

  # Where a cloud SDK, or a later RubyLLM, would look for credentials of its
  # own, beside each provider's conventional key variable.
  def planted_env(home)
    { "GOOGLE_APPLICATION_CREDENTIALS" => File.join(home, "#{ambient}.json"), "CLOUDSDK_CONFIG" => home,
      "AWS_ACCESS_KEY_ID" => "AKIA#{ambient}", "AWS_SECRET_ACCESS_KEY" => ambient, "AWS_SESSION_TOKEN" => ambient,
      "AWS_PROFILE" => ambient, "AWS_SHARED_CREDENTIALS_FILE" => File.join(home, ".aws", "credentials"),
      "AWS_CONFIG_FILE" => File.join(home, ".aws", "config"), "AZURE_CLIENT_ID" => ambient,
      "AZURE_CLIENT_SECRET" => ambient, "AZURE_TENANT_ID" => ambient, "AZURE_OPENAI_API_KEY" => ambient,
      "GOOGLE_API_KEY" => ambient, "HOME" => home,
      **providers.to_h { ["#{_1.upcase}_API_KEY", ambient] } }
  end

  def plant_files(home)
    { "#{ambient}.json" => JSON.generate("type" => "service_account", "private_key_id" => ambient),
      ".config/gcloud/application_default_credentials.json" => JSON.generate("refresh_token" => ambient),
      ".aws/credentials" => "[default]\naws_access_key_id = AKIA#{ambient}\naws_secret_access_key = #{ambient}\n",
      ".aws/config" => "[profile #{ambient}]\nregion = us-east-1\n",
      ".netrc" => "machine 127.0.0.1 login #{ambient} password #{ambient}\n" }.each do |path, text|
      FileUtils.mkdir_p(File.dirname(File.join(home, path)))
      File.write(File.join(home, path), text)
    end
  end

  # Every provider's secret and endpoint in RubyLLM's global configuration,
  # pointing elsewhere.
  def plant_config
    Smith::ProviderOptions::TABLE.each do |provider, options|
      options.each do |option, kind|
        value = case kind
                when :secret then "#{ambient}-#{option}"
                when :endpoint then option == :api_base ? elsewhere.url : "#{ambient}-#{option}"
                end
        RubyLLM.config.public_send(:"#{provider}_#{option}=", value) if value
      end
    end
  end

  around do |example|
    names = planted_env("").keys
    env = names.to_h { [_1, ENV.fetch(_1, nil)] }
    options = Smith::ProviderOptions::TABLE.flat_map { |provider, kinds| kinds.keys.map { :"#{provider}_#{_1}" } }
    config = options.to_h { [_1, RubyLLM.config.public_send(_1)] }
    $LOAD_PATH.unshift(stand_in)
    Dir.mktmpdir do |home|
      plant_files(home)
      planted_env(home).each { |name, value| ENV[name] = value }
      example.run
    end
  ensure
    $LOAD_PATH.delete(stand_in)
    env.each { |name, value| ENV[name] = value }
    config.each { |option, value| RubyLLM.config.public_send(:"#{option}=", value) }
    elsewhere.close
  end

  before do
    plant_config
    Google::Auth.calls.clear if defined?(Google::Auth)
  end

  def model_of(provider)
    { anthropic: "claude-sonnet-5-5", azure: "gpt-5", bedrock: "anthropic.claude-sonnet-4-5-v1:0",
      deepseek: "deepseek-chat", gemini: "gemini-2.5-flash", gpustack: "qwen3", mistral: "mistral-large-latest",
      ollama: "llama3.2", openai: "gpt-5", openrouter: "openai/gpt-5", perplexity: "sonar",
      vertexai: "gemini-2.5-flash", xai: "grok-4" }.fetch(provider)
  end

  def account
    pem = "-----BEGIN PRIVATE KEY-----\n#{SecureRandom.base64(96)}\n-----END PRIVATE KEY-----\n"
    JSON.generate("type" => "service_account", "project_id" => "cust-proj-1", "private_key_id" => account_id,
                  "private_key" => pem, "client_email" => "evals@cust-proj-1.iam.gserviceaccount.com")
  end

  # What a run declares for each provider, its endpoint the local server.
  def declared(provider)
    base = { api_base: server.url }
    case provider
    when :vertexai then { project_id: "cust-proj-1", location: "us-central1", service_account_key: account, **base }
    when :bedrock then { api_key: "AKIA#{key_id}", secret_key: canary, region: "us-east-1", **base }
    when :ollama, :gpustack then base
    else { api_key: canary, **base }
    end
  end

  # What a request may carry to say who calls: the run's key, the token its
  # service account key gives, or a signature naming its access key id.
  def own?(value) = [canary, "Bearer sa-#{account_id}", "Credential=AKIA#{key_id}/"].any? { value.include?(_1) }

  def credential_headers(request)
    request.headers.select do |name, _value|
      name.match?(/authorization|api-key|token|organization|project|cookie|security|x-goog/)
    end
  end

  def wire(request) = [request.path, *request.headers.to_a.flatten, request.raw].join("\n")

  # A run on `provider`, its block answering `given` (or what `build` builds).
  def run_on(provider, given, credentialed: true, &build)
    name = "SpecAmbient#{provider.to_s.capitalize}"
    agent("#{name}Agent", register: :"spec_ambient_#{provider}", model: model_of(provider), provider:)
    asking("#{name}Flow", agent: :"spec_ambient_#{provider}", credentialed:, returning: build || -> { given })
      .new(context:).run!
  end

  it "knows every provider RubyLLM registers" do
    expect(providers.sort).to eq(Smith::ProviderOptions::TABLE.keys.sort)
    expect(providers.map { model_of(_1) }.length).to eq(providers.length)
  end

  RubyLLM::Provider.providers.each_key do |provider|
    it "sends #{provider} only what the run's credentials hold, with ambient ones planted everywhere" do
      run_on(provider, Smith::ProviderCredentials.new(provider => declared(provider)))
      sent = server.requests
      headers = sent.flat_map { credential_headers(_1).values }

      expect(sent).not_to be_empty
      expect(elsewhere.requests).to eq([])
      expect(sent.map { wire(_1) }.join).not_to include(ambient)
      expect(headers.reject { own?(_1) }).to eq([])
      expect(headers).to eq([]) if %i[ollama gpustack].include?(provider)
      expect(headers).not_to be_empty unless %i[ollama gpustack].include?(provider)
      expect(defined?(Google::Auth) ? Google::Auth.calls : []).not_to include(:application_default)
    end
  end

  it "refuses, under the fail-closed mode, a run without credentials on every provider, before anything is sent" do
    Smith.config.require_run_credentials = true
    errors = providers.map { run_on(_1, nil, credentialed: false).last_error }

    expect(errors.map(&:class).uniq).to eq([Smith::ProviderCredentialsMissing])
    expect(server.requests + elsewhere.requests).to eq([])
    expect(defined?(Google::Auth) ? Google::Auth.calls : []).to eq([])
  end

  it "skips, sending nothing, every provider a run's credentials do not cover" do
    errors = providers.map do |provider|
      other = provider == :anthropic ? :openai : :anthropic
      run_on(provider, Smith::ProviderCredentials.new(other => declared(other))).last_error
    end

    expect(errors.map(&:class).uniq).to eq([Smith::ProviderCredentialsMissing])
    expect(server.requests + elsewhere.requests).to eq([])
  end

  # googleauth completes a service account key without project_id from the
  # worker's own gcloud (`gcloud config config-helper`), at every attempt;
  # such a key is refused before googleauth is asked.
  it "refuses a service account key googleauth would complete from the machine, before it is asked" do
    trimmed = JSON.generate(JSON.parse(account).except("project_id"))
    key = { project_id: "cust-proj-1", location: "us-central1", service_account_key: trimmed, api_base: server.url }
    error = run_on(:vertexai, nil) { Smith::ProviderCredentials.new(vertexai: key) }.last_error

    expect(error).to be_a(Smith::ProviderCredentialsError)
    expect(error.message).to include("project_id")
    expect([server.requests, defined?(Google::Auth) ? Google::Auth.calls : []]).to eq([[], []])
  end

  # RubyLLM itself, given a provider's endpoints and none of its secrets:
  # a provider that still sends a credential (one it found on the machine,
  # as Vertex AI asks Google's application default credentials, or an empty
  # one) is one whose credential Smith requires a run to name; a local one
  # sends none.
  it "finds, from a context naming no credential, one of its own only for a provider Smith requires one of" do
    sending = providers.select do |provider|
      endpoints = declared(provider).reject { |option, _| Smith::ProviderOptions.secret?(provider, option) }
      settings = endpoints.to_h { |option, value| [:"#{provider}_#{option}", value] }
      quiet = Smith::ProviderOptions.context(settings, instrumenter: false)
      sent = server.requests.length
      begin
        RubyLLM.chat(model: model_of(provider), provider:, assume_model_exists: true, context: quiet).ask("Hi")
      rescue StandardError
        nil
      end
      server.requests.drop(sent).any? { credential_headers(_1).any? } ||
        (defined?(Google::Auth) && Google::Auth.calls.delete(:application_default))
    end
    named = sending.to_h do |provider|
      endpoints = declared(provider).reject { |option, _| Smith::ProviderOptions.secret?(provider, option) }
      [provider, Smith::ProviderCredentials.new(provider => endpoints)]
    rescue ArgumentError
      [provider, :refused]
    end

    expect(sending).to include(:vertexai)
    expect(sending & %i[ollama gpustack]).to eq([])
    expect(named.values.uniq).to eq([:refused])
  end

  # What RubyLLM's configuration_requirements name is enough to build a
  # provider, and for Vertex AI or Azure not a credential: every provider but
  # a local one also needs the one it sends.
  it "refuses credentials that name what a provider requires but not the credential it sends, a local one aside" do
    accepted = providers.select do |provider|
      needs = RubyLLM::Provider.resolve(provider).configuration_requirements
                               .map { _1.to_s.delete_prefix("#{provider}_").to_sym }
      endpoints = declared(provider).slice(*needs).reject { |option, _| Smith::ProviderOptions.secret?(provider, option) }
      Smith::ProviderCredentials.new(provider => endpoints)
    rescue ArgumentError
      false
    end

    expect(accepted).to eq(%i[gpustack ollama])
  end
end
