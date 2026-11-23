# frozen_string_literal: true

require "json"
require "logger"
require "uri"
require "ruby_llm"

module Smith
  # Where run credentials (slice 1c) meet RubyLLM: which of a provider's
  # options a run's credentials set and must hold (Checks), the context a
  # credentialed run's chats are built on, the provider an unqualified model
  # belongs to, a provider error's scrubbed copy, and what RubyLLM's global
  # configuration, its logger and the machine hold.
  #
  # Every RubyLLM touch point of run credentials, each checked by
  # spec/smith/contracts/ruby_llm_spec.rb or run_credentials_providers_spec.rb
  # (the RubyLLM pin moves only when they pass on the new version):
  # - here: Provider.providers, each class's configuration_options and
  #   configuration_requirements, Provider.resolve, RubyLLM.context and each
  #   option's setter, config.instrumenter, RubyLLM.models.find(id).provider,
  #   error.class.new(Faraday::Response, message), the Unauthorized,
  #   PaymentRequired and Forbidden error classes, config.logger, log_level
  #   and log_stream_debug, and the logger RubyLLM keeps once used (@logger);
  # - Agent::AttemptChat#attempt_chat, ImageAttempt#painting_chat:
  #   RubyLLM::Agent.chat(context:), a keyword that is not an input;
  #   AttemptChat#sent_once: RubyLLM::Context#config and Context.new;
  # - RunCredentials#check_agent!, RunCredentialsReadiness: the agent DSL's
  #   context and inputs readers;
  # - ProviderCredentialsScrubber#copied: RubyLLM::Error#response, its status
  #   and body;
  # - Workflow::BatchCharges: Providers::Anthropic::Chat's
  #   parse_completion_response, called on the module;
  # - behaviours: a provider finds no credential of its own once its context
  #   names the one CREDENTIALS lists (Vertex AI otherwise asks Google's
  #   application default credentials), and RubyLLM writes bodies when its
  #   logger is at DEBUG. One more, which the canary matrix guards rather
  #   than a contract: on Ruby 4 every RubyLLM configuration, context, chat,
  #   provider and connection prints its keys, so a run keeps none of them
  #   outside its binding.
  module ProviderOptions
    # Each registered provider's options at RubyLLM 1.16.0, named without
    # their provider's prefix: :secret (a key, token or account id: cleared in
    # a run's context, set only from its credentials, scrubbed from what it
    # raises), :endpoint (where requests go, a Vertex AI project among them,
    # which its URLs carry: cleared and set the same, not a secret) or
    # :setting (kept from the global configuration). An option a later
    # RubyLLM adds is cleared in a run's context until it is named here.
    TABLE = {
      anthropic: { api_key: :secret, api_base: :endpoint },
      azure: { api_base: :endpoint, api_key: :secret, ai_auth_token: :secret },
      bedrock: { api_key: :secret, secret_key: :secret, region: :endpoint, session_token: :secret,
                 api_base: :endpoint },
      deepseek: { api_key: :secret, api_base: :endpoint },
      gemini: { api_key: :secret, api_base: :endpoint },
      gpustack: { api_base: :endpoint, api_key: :secret },
      mistral: { api_key: :secret, api_base: :endpoint },
      ollama: { api_base: :endpoint, api_key: :secret },
      openai: { api_key: :secret, api_base: :endpoint, organization_id: :secret, project_id: :secret,
                use_system_role: :setting },
      openrouter: { api_key: :secret, api_base: :endpoint },
      perplexity: { api_key: :secret, api_base: :endpoint },
      vertexai: { project_id: :endpoint, location: :endpoint, service_account_key: :secret, api_base: :endpoint },
      xai: { api_key: :secret, api_base: :endpoint }
    }.freeze

    # The credential each provider sends to say who calls, which a run's
    # credentials must name (one of these sets): given none, RubyLLM would
    # find one of its own (Vertex AI asks Google's application default
    # credentials, the worker's own identity) or refuse late. A local Ollama
    # or GPUStack sends none unless given a key.
    CREDENTIALS = {
      anthropic: [%i[api_key]], azure: [%i[api_key], %i[ai_auth_token]], bedrock: [%i[api_key secret_key]],
      deepseek: [%i[api_key]], gemini: [%i[api_key]], gpustack: [[]], mistral: [%i[api_key]], ollama: [[]],
      openai: [%i[api_key]], openrouter: [%i[api_key]], perplexity: [%i[api_key]],
      vertexai: [%i[service_account_key]], xai: [%i[api_key]]
    }.freeze

    # A refusal by Checks or ServiceAccount: its message names providers,
    # options and fields Smith or RubyLLM know, never a value, so run
    # credentials pass it on to the host (ProviderCredentialsError).
    class Invalid < ArgumentError; end

    module_function

    # A provider's options as a run may set them (Checks).
    def check!(provider, options) = Checks.provider!(provider, options)

    def secret?(provider, option) = TABLE.dig(provider, option) == :secret

    # What a scrub looks for of a secret value: the value, or, for a service
    # account key (JSON, much of it ordinary text such as
    # https://www.googleapis.com), its private key's body and the key's id.
    def secret_parts(provider, option, value)
      return [value] unless provider == :vertexai && option == :service_account_key

      ServiceAccount.parts(value)
    end

    # The RubyLLM option a provider's option sets.
    def option_name(provider, option) = :"#{provider}_#{option}"

    # An isolated RubyLLM context: the global configuration copied, every
    # provider's secret and endpoint options cleared (so nothing falls back
    # to a global key), `settings` ({option => value}) set, and no
    # instrumenter unless `instrumenter` (so no subscriber sees a raw
    # request).
    def context(settings, instrumenter:)
      RubyLLM.context do |config|
        cleared.each { config.public_send(:"#{_1}=", nil) }
        settings.each { |option, value| config.public_send(:"#{option}=", value) }
        config.instrumenter = nil unless instrumenter
      end
    end

    # The provider RubyLLM's model registry names for a model id, or nil.
    def provider_of(model_id)
      RubyLLM.models.find(model_id.to_s).provider&.to_sym
    rescue StandardError
      nil
    end

    # A provider error built again through RubyLLM's public constructor: the
    # same class and backtrace, `message`, and a response holding only
    # `status` and `body` (no request, so no headers), with no cause.
    def copy(error, status:, body:, message:)
      response = Faraday::Response.new(status:, body:, response_headers: {})
      error.class.new(response, message).tap { _1.set_backtrace(error.backtrace) if error.backtrace }
    end

    def provider_error?(error) = error.is_a?(RubyLLM::Error)

    # How a provider refused the run's key, as Smith takes the error
    # (BillingRefusals makes a billing refusal a 402): :key_refused (401),
    # :out_of_credit (402) or :permission (403), else nil.
    def refusal_kind(error)
      case error
      when RubyLLM::UnauthorizedError then :key_refused
      when RubyLLM::PaymentRequiredError then :out_of_credit
      when RubyLLM::ForbiddenError then :permission
      end
    end

    # Whether RubyLLM's global configuration holds any provider's secret.
    def global_secrets?
      config = RubyLLM.config
      TABLE.any? do |provider, options|
        options.any? { |option, kind| kind == :secret && present?(config.public_send(option_name(provider, option))) }
      end
    rescue StandardError
      false
    end

    # Why RubyLLM's own logger, global, writes response bodies, or nil.
    # RubyLLM logs with the logger it kept once used, else config.logger (a
    # Rails host's Rails.logger), else a Logger at config.log_level (an
    # Integer, Symbol or String, as Logger takes them). All are read: one set
    # after RubyLLM's first use is not yet the one in force. Bodies go at
    # DEBUG, streamed chunks with log_stream_debug.
    def body_logging
      config = RubyLLM.config
      return "log_stream_debug is on" if config.log_stream_debug
      return "the logger RubyLLM logs with is at DEBUG" if debug?(RubyLLM.instance_variable_get(:@logger))
      return "config.logger is at DEBUG" if debug?(config.logger)
      return if config.logger

      level = config.log_level
      "config.log_level #{level.inspect} is DEBUG" if Logger.new(IO::NULL, level:).debug?
    rescue ArgumentError
      "config.log_level #{level.inspect} is no level Logger takes"
    end

    # The names (never values) of credentials found in the environment or on
    # the machine (Ambient).
    def ambient_credentials = Ambient.found

    def debug?(logger) = !logger.nil? && (!logger.respond_to?(:debug?) || logger.debug?)

    # Every registered provider's options a run's context clears: all but
    # the settings TABLE names.
    def cleared
      RubyLLM::Provider.providers.flat_map do |provider, klass|
        klass.configuration_options.reject do |option|
          TABLE.fetch(provider, {})[option.to_s.delete_prefix("#{provider}_").to_sym] == :setting
        end
      end
    end

    def provider_class(provider) = TABLE.key?(provider) && RubyLLM::Provider.resolve(provider)

    def requirements(provider)
      provider_class(provider).configuration_requirements.map { _1.to_s.delete_prefix("#{provider}_").to_sym }
    end

    def present?(value) = value.is_a?(String) && !value.strip.empty?
    private_class_method :cleared, :debug?

    # Where a cloud SDK finds credentials of its own (Google's application
    # default credentials, AWS's default chain, Azure's identity): RubyLLM
    # reads none of them once a run names each provider's credential, but a
    # host's own calls could. Variables, and files by the variable that moves
    # them. A metadata server is not asked.
    module Ambient
      VARIABLES = %w[GOOGLE_APPLICATION_CREDENTIALS GOOGLE_PRIVATE_KEY GOOGLE_CLIENT_SECRET GOOGLE_REFRESH_TOKEN
                     AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
                     AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_CONTAINER_CREDENTIALS_FULL_URI
                     AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID
                     AZURE_CLIENT_CERTIFICATE_PATH AZURE_FEDERATED_TOKEN_FILE AZURE_USERNAME AZURE_PASSWORD].freeze
      # gcloud's own login (credentials.db, access_tokens.db) is what
      # googleauth's gcloud call reads; the system file is ADC's last place.
      FILES = {
        "~/.config/gcloud/application_default_credentials.json" => %w[CLOUDSDK_CONFIG
                                                                      application_default_credentials.json],
        "~/.config/gcloud/credentials.db" => %w[CLOUDSDK_CONFIG credentials.db],
        "~/.config/gcloud/access_tokens.db" => %w[CLOUDSDK_CONFIG access_tokens.db],
        "/etc/google/auth/application_default_credentials.json" => [],
        "~/.aws/credentials" => ["AWS_SHARED_CREDENTIALS_FILE"], "~/.aws/config" => ["AWS_CONFIG_FILE"],
        "~/.azure/msal_token_cache.json" => []
      }.freeze

      module_function

      def found
        VARIABLES.select { set?(_1) } + places.filter_map { |name, path| name if File.file?(path) }.uniq
      rescue ArgumentError
        VARIABLES.select { set?(_1) }
      end

      # [name, path] of each file: where it is by default, and where its
      # variable moves it.
      def places
        FILES.flat_map do |default, (variable, inside)|
          here = [default, File.expand_path(default)]
          next [here] unless variable && set?(variable)

          [here, ["$#{[variable, inside].compact.join("/")}", File.join(ENV.fetch(variable), *inside)]]
        end
      end

      def set?(variable) = ProviderOptions.present?(ENV.fetch(variable, nil))
    end
    private_constant :Ambient

    # A Google service account key as googleauth reads one: type
    # service_account, a PEM private_key, a client_email and a project_id
    # (without one, googleauth runs the worker's own gcloud for its project
    # at every attempt). Its secret parts are the private key's base64 body
    # and the key's id; the client email names the account (Google's own
    # errors print it), the rest is ordinary text. Messages name fields,
    # never values, nor a JSON parser's quote.
    module ServiceAccount
      LABEL = /\A-----(BEGIN|END) [A-Z ]*PRIVATE KEY-----\z/
      RULE = "vertexai service_account_key"

      module_function

      def parts(json)
        key = parsed(json)
        raise Invalid, "#{RULE} must be of type service_account" unless
          key.fetch("type", "service_account") == "service_account"

        %w[client_email project_id].each do |field|
          raise Invalid, "#{RULE} needs a #{field}" unless ProviderOptions.present?(key[field])
        end

        [body!(key["private_key"]), id!(key["private_key_id"])].compact
      end

      def parsed(json)
        key = JSON.parse(json)
        key.is_a?(Hash) ? key : raise(Invalid, "#{RULE} must be a JSON object")
      rescue JSON::ParserError
        raise Invalid, "#{RULE} must be JSON"
      end

      def body!(pem)
        lines = pem.to_s.lines.map(&:strip).reject(&:empty?)
        body = lines[1...-1].to_a.join
        return body if lines.length > 2 && lines.values_at(0, -1).all?(LABEL) &&
                       body.match?(%r{\A[A-Za-z0-9+/=]+\z}) && body.bytesize >= Checks::SECRET_BYTES

        raise Invalid, "#{RULE} needs a PEM private_key"
      end

      def id!(id)
        return if id.nil?
        return id if id.is_a?(String) && id.bytesize >= Checks::SECRET_BYTES

        raise Invalid, "#{RULE} private_key_id must be a String of #{Checks::SECRET_BYTES} bytes or more"
      end
    end
    private_constant :ServiceAccount

    # A provider's options as a run may set them, keys without the prefix:
    # its own secret and endpoint options, String values (each secret part
    # of at least SECRET_BYTES, the least a scrub can match without matching
    # ordinary text: ProviderCredentialsScrubber::LONG), a base URL with no
    # user information or query (RubyLLM's logger writes URLs), what the
    # provider needs to be built, and the credential it sends (CREDENTIALS).
    # Messages name options, never values.
    module Checks
      PER_RUN = %i[secret endpoint].freeze
      VALUE_BYTES = 16_384
      SECRET_BYTES = 16
      URL_RULE = "must be an http or https URL with no user information or query"

      module_function

      def provider!(provider, options)
        name = known!(provider, options)
        checked = options.to_h { |option, value| option!(name, option.to_s.to_sym, value) }
        missing = ProviderOptions.requirements(name) - checked.keys
        raise Invalid, "#{name}'s credentials need #{missing.join(", ")}" unless missing.empty?

        credential!(name, checked.keys)
        checked.freeze
      end

      # The run names the credential the provider sends, so RubyLLM never
      # finds one of its own.
      def credential!(provider, named)
        sets = CREDENTIALS.fetch(provider)
        return if sets.any? { (_1 - named).empty? }

        raise Invalid, "#{provider}'s credentials need #{sets.map { _1.join(" and ") }.join(" or ")}, the " \
                       "credential it sends, or RubyLLM would find one of its own"
      end

      # A name the host wrote where a provider or an option goes is shown
      # only when RubyLLM knows it: a key put there by mistake never is.
      def known!(provider, options)
        name = provider.to_s.to_sym
        shown = RubyLLM::Provider.providers.key?(name) ? name : "the name given"
        raise Invalid, "#{shown} is not a provider run credentials know" unless ProviderOptions.provider_class(name)
        raise Invalid, "#{name}'s credentials must be a Hash of its options" unless options.is_a?(Hash)

        name
      end

      def option!(provider, option, value)
        kind = TABLE[provider][option]
        unless PER_RUN.include?(kind)
          known = TABLE.values.any? { _1.key?(option) } || RubyLLM::Configuration.options.include?(option)
          raise Invalid, "#{known ? option : "the option given"} is not one of #{provider}'s secret or endpoint options"
        end

        value!(provider, option, value, kind == :secret ? SECRET_BYTES : 1)
        base!(provider, option, value) if option == :api_base
        ProviderOptions.secret_parts(provider, option, value) if kind == :secret
        [option, value.dup.freeze]
      end

      def value!(provider, option, value, least)
        return if value.is_a?(String) && value.valid_encoding? && ProviderOptions.present?(value) &&
                  (least..VALUE_BYTES).cover?(value.bytesize)

        raise Invalid, "#{provider} #{option} must be a String of #{least} to #{VALUE_BYTES} bytes"
      end

      def base!(provider, option, value)
        uri = URI.parse(value)
        return if uri.is_a?(URI::HTTP) && uri.host && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?

        raise Invalid, "#{provider} #{option} #{URL_RULE}"
      rescue URI::InvalidURIError
        raise Invalid, "#{provider} #{option} #{URL_RULE}"
      end
    end
    private_constant :Checks
  end
end
