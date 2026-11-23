# frozen_string_literal: true

require "json"
require "pp"
require "yaml"
require "smith/provider_credentials"

# A run's provider keys (additions design 3.3): each provider's own secret
# and endpoint options, checked when built, printed by provider name only,
# and never serialized.
RSpec.describe Smith::ProviderCredentials do
  let(:key) { "sk-canary-#{"0123456789abcdef" * 2}" }

  def build(**providers) = described_class.new(**providers)

  it "holds each provider's own secret and endpoint options, and says which providers it covers" do
    openai = { "api_key" => key, organization_id: "org-0123456789abcdefghijklmn", api_base: "https://proxy.example/v1" }
    credentials = build(anthropic: { api_key: key }, "openai" => openai)

    expect(credentials.providers).to eq(%i[anthropic openai])
    expect(credentials.providers).to be_frozen
    expect(credentials).to be_frozen
    expect([credentials.covers?(:anthropic), credentials.covers?("openai"), credentials.covers?(:gemini),
            credentials.covers?(nil)]).to eq([true, true, false, false])
  end

  # A service account key shaped as Google issues them (fake values).
  def service_account(**overrides)
    JSON.pretty_generate({ "type" => "service_account", "project_id" => "cust-proj-1",
                           "private_key_id" => "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c",
                           "private_key" => "-----BEGIN PRIVATE KEY-----\n#{body}\n-----END PRIVATE KEY-----\n",
                           "client_email" => "evals@cust-proj-1.iam.gserviceaccount.com",
                           "client_id" => "104729563810294756381",
                           "token_uri" => "https://oauth2.googleapis.com/token",
                           "universe_domain" => "googleapis.com" }.merge(overrides.transform_keys(&:to_s)).compact)
  end

  def body = (["MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQC7#{"q1Zx/+8Vb" * 6}"] * 4).join("\n")

  it "takes a local provider, which sends no credential unless given a key, with what it needs alone" do
    { ollama: { api_base: "http://127.0.0.1:11434/v1" }, gpustack: { api_base: "http://127.0.0.1:8080" } }
      .each do |provider, options|
        credentials = build(provider => options)
        expect([credentials.covers?(provider), credentials.secret_values]).to eq([true, []]), provider.to_s
      end
    expect { build(ollama: { api_base: "http://127.0.0.1:11434/v1", api_key: "x" }) }
      .to raise_error(ArgumentError, /ollama api_key must be a String of 16/)
  end

  # RubyLLM finds a credential of its own for a provider given none: Vertex
  # AI asks Google's application default credentials (the worker's own
  # identity), and Azure sends an empty token. A run names the one it sends.
  it "refuses every other provider without the credential it sends, Vertex AI's service account key included" do
    refused = {
      vertexai: [{ project_id: "cust-proj-1", location: "us-central1" }, /service_account_key/],
      azure: [{ api_base: "https://example.openai.azure.com" }, /api_key or ai_auth_token/],
      bedrock: [{ api_key: "AKIA0123456789ABCDEF", region: "us-east-1" }, /secret_key/],
      anthropic: [{ api_base: "https://api.example" }, /api_key/]
    }

    refused.each do |provider, (options, named)|
      expect { build(provider => options) }.to raise_error(ArgumentError, named), provider.to_s
    end
    expect(build(azure: { api_base: "https://example.openai.azure.com", ai_auth_token: key }).secret_values)
      .to eq([key])
  end

  it "scrubs a service account key by its secret parts, the private key and its id, never the whole document" do
    credentials = build(vertexai: { project_id: "cust-proj-1", location: "us", service_account_key: service_account })

    expect(credentials.secret_values).to contain_exactly(body.delete("\n"), "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c")
    expect(credentials.secret_values.join).not_to include("googleapis", "cust-proj-1", "evals@", "BEGIN")
    expect(credentials.ruby_llm_settings).to eq(vertexai_project_id: "cust-proj-1", vertexai_location: "us",
                                                vertexai_service_account_key: service_account)
  end

  it "refuses a service account key that is not one, naming the problem and never the key" do
    refused = {
      "not JSON" => "{\"private_key\": \"#{body}",
      "not a JSON object" => JSON.generate([service_account]),
      "another credential type (it would be read from elsewhere)" => service_account(type: "external_account"),
      "no private key" => service_account(private_key: nil),
      "a private key that is not PEM" => service_account(private_key: body),
      "no client email" => service_account(client_email: nil),
      "no project id (googleauth would ask the worker's own gcloud for one)" => service_account(project_id: nil),
      "a key id too short to scrub" => service_account(private_key_id: "0f1e2d")
    }

    refused.each do |label, json|
      expect { build(vertexai: { project_id: "p-1", location: "us", service_account_key: json }) }
        .to raise_error(ArgumentError, /service_account_key/) { |error|
          expect(error.message).not_to include(body[0, 12]), label
        }, label
    end
  end

  it "takes a short endpoint value, such as a Vertex AI project id or region, which is not scrubbed" do
    credentials = build(vertexai: { project_id: "prod-1", location: "us", service_account_key: service_account })

    expect(credentials.secret_values).not_to include("prod-1", "us")
    expect(credentials.ruby_llm_settings).to include(vertexai_project_id: "prod-1", vertexai_location: "us")
  end

  it "refuses an unknown provider, another provider's option, a setting, a process-wide option and bad values" do
    refused = {
      "unknown provider" => { acme: { api_key: key } },
      "another provider's option" => { anthropic: { api_key: key, organization_id: "org-1" } },
      "a setting, which is kept from the global configuration" => { openai: { api_key: key, use_system_role: "1" } },
      "a process-wide option" => { anthropic: { api_key: key, log_file: "/tmp/x" } },
      "a value that is not a String" => { anthropic: { api_key: 42 } },
      "a blank value" => { anthropic: { api_key: "  " } },
      "a secret too short to tell apart from ordinary text" => { anthropic: { api_key: "test" } },
      "a secret shorter than the 16 bytes a scrub matches safely" => { anthropic: { api_key: "password1" } },
      "options that are not a Hash" => { anthropic: key },
      "a provider without what it needs" => { anthropic: { api_base: "https://api.example" } },
      "a base URL with user information" => { anthropic: { api_key: key, api_base: "https://u:#{key}@api.example" } },
      "a base URL with a query" => { anthropic: { api_key: key, api_base: "https://api.example/?key=#{key}" } },
      "a base URL that is not http or https" => { anthropic: { api_key: key, api_base: "file:///etc/passwd" } }
    }

    refused.each do |label, providers|
      expect { build(**providers) }.to raise_error(ArgumentError) { |error|
        expect(error.message).not_to include(key), label
        expect(error.message).not_to include("u:"), label
      }, label
    end
  end

  # Its messages reach the host (ProviderCredentialsError), so a key put
  # where a provider or an option is named never shows in one.
  it "names an unknown provider or option only when it is one RubyLLM knows" do
    expect { build(key => { api_key: key }) }
      .to raise_error(ArgumentError, "the name given is not a provider run credentials know")
    expect { build(anthropic: { key => "https://api.example" }) }
      .to raise_error(ArgumentError, "the option given is not one of anthropic's secret or endpoint options")
    expect { build(anthropic: { api_key: key, log_file: "/tmp/x" }) }
      .to raise_error(ArgumentError, /log_file is not one of anthropic's/)
  end

  it "prints only its provider names, through inspect, to_s and pp" do
    credentials = build(anthropic: { api_key: key }, openai: { api_key: key })
    printed = [credentials.inspect, credentials.to_s, credentials.pretty_inspect, "printed: #{credentials}"]

    expect(credentials.inspect).to eq("#<Smith::ProviderCredentials anthropic, openai>")
    printed.each { expect(_1).not_to include(key[10, 12]) }
  end

  it "refuses JSON, YAML and Marshal, and every serialization hook" do
    credentials = build(anthropic: { api_key: key })
    attempts = {
      "JSON.generate" => -> { JSON.generate(credentials) },
      "JSON.generate in a Hash" => -> { JSON.generate(credentials: credentials) },
      "to_json" => -> { credentials.to_json },
      "as_json" => -> { credentials.as_json },
      "to_h" => -> { credentials.to_h },
      "YAML.dump" => -> { YAML.dump(credentials) },
      "encode_with" => -> { credentials.encode_with(nil) },
      "Marshal.dump" => -> { Marshal.dump(credentials) },
      "marshal_dump" => -> { credentials.marshal_dump },
      "_dump" => -> { credentials._dump(0) }
    }

    attempts.each do |label, attempt|
      expect { attempt.call }.to raise_error(Smith::SecretSerializationError) { |error|
        expect(error.message).not_to include(key[10, 12]), label
      }, label
    end
  end
end
