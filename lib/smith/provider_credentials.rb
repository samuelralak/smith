# frozen_string_literal: true

require_relative "errors"
require_relative "provider_options"

module Smith
  # A run's provider keys, as a workflow's `provider_credentials` block
  # returns them: for each provider, its own secret and endpoint options,
  # named without their prefix (ProviderOptions::TABLE says which):
  #
  #   Smith::ProviderCredentials.new(anthropic: { api_key: key },
  #                                  openai: { api_key: other, organization_id: org })
  #
  # Checked when built (ProviderOptions.check!: each provider's own options,
  # and the credential it sends, so RubyLLM never finds one of its own),
  # frozen, printed by provider name only, and never serialized: JSON, YAML
  # and Marshal raise SecretSerializationError. Loaded by a workflow class that declares
  # `provider_credentials`, or by `require "smith/provider_credentials"`.
  class ProviderCredentials
    attr_reader :providers

    def initialize(**providers)
      @options = providers.to_h do |provider, options|
        [provider.to_s.to_sym, ProviderOptions.check!(provider, options)]
      end.freeze
      @providers = @options.keys.freeze
      freeze
    end

    def covers?(provider) = !provider.nil? && @options.key?(provider.to_s.to_sym)

    def inspect = "#<#{self.class.name} #{@providers.join(", ")}>"
    alias to_s inspect

    def pretty_print(printer) = printer.text(inspect)

    # What Smith sets in a run's RubyLLM context: {RubyLLM option => value}.
    # Internal to run credentials.
    def ruby_llm_settings
      @options.flat_map do |provider, options|
        options.map { |option, value| [ProviderOptions.option_name(provider, option), value] }
      end.to_h
    end

    # What run credentials scrub from what a run raises: each secret value,
    # or a structured one's secret parts (ProviderOptions.secret_parts).
    # Internal to run credentials.
    def secret_values
      @options.flat_map do |provider, options|
        options.flat_map do |option, value|
          ProviderOptions.secret?(provider, option) ? ProviderOptions.secret_parts(provider, option, value) : []
        end
      end
    end

    %i[to_h to_json as_json encode_with marshal_dump _dump].each do |name|
      define_method(name) { |*| raise SecretSerializationError }
    end
  end
end
