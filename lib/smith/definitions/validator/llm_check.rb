# frozen_string_literal: true

require_relative "../../provider_options"

module Smith
  module Definitions
    class Validator
      # The llm block: a provider Smith runs and a model, fallbacks each
      # naming both, and format 1's settings, each checked against the
      # model as Smith's tables describe it (the profile Smith::Models gives
      # the runtime): a temperature the model refuses, thinking it does not
      # do or takes in the other form, or an output limit Smith cannot set
      # for the provider is refused, so a variant fails before it runs.
      # Fallbacks take the model's settings, shaped for each by Smith's
      # normalizer at run time, as for an agent written in Ruby.
      class LlmCheck
        include Checks

        TAKES = { budget_tokens: "budget", reasoning_effort: "effort", adaptive: "effort" }.freeze
        ONE_FORM = "is an object with one of effort or budget"

        # `models`: check the settings against the model table, as when a
        # definition is created or imported; not when a stored one is read.
        def initialize(problems, models:)
          @problems = problems
          @models = models
        end

        def check(llm)
          return unless object!(llm, "/llm")

          fields!(llm, "/llm", LLM_FIELDS, "a field of llm")
          model = model!(llm, "/llm")
          need(boolean?(llm["assume_exists"]), "/llm/assume_exists", "is true or false") if llm.key?("assume_exists")
          settings = llm.key?("settings") ? settings!(llm["settings"], "/llm/settings") : {}
          fallbacks!(llm["fallbacks"], model) if llm.key?("fallbacks")
          taken!(*model, settings, "/llm/settings") if model && settings
        end

        private

        # [provider, model id] when both can be read, else nil.
        def model!(object, path)
          provider = required(object, "provider", path) { provider!(_1, "#{path}/provider") }
          model = required(object, "model", path) do |id|
            need(id.is_a?(String) && MODEL.match?(id), "#{path}/model", MODEL_RULE) && id
          end
          [provider, model] if provider && model
        end

        def provider!(name, path)
          known = ProviderOptions::TABLE.each_key.find { _1.name == name } if name.is_a?(String)
          return known if known && ProviderOptions.provider_class(known)

          problem(path, "is a provider Smith runs: #{ProviderOptions::TABLE.keys.join(", ")}")
        end

        # The settings when each can be read, else nil.
        def settings!(settings, path)
          return unless object!(settings, path)

          before = @problems.size
          fields!(settings, path, SETTINGS, "a setting of format 1")
          temperature = settings.fetch("temperature", 0)
          need((temperature.is_a?(Integer) || temperature.is_a?(Float)) && temperature.between?(0, 2),
               "#{path}/temperature", "is a number from 0 to 2")
          need(integer?(settings.fetch("max_output_tokens", 1), 1), "#{path}/max_output_tokens",
               "is an Integer of at least 1")
          thinking!(settings["thinking"], "#{path}/thinking") if settings.key?("thinking")
          settings if @problems.size == before
        end

        def thinking!(thinking, path)
          fields!(thinking, path, THINKING, "a field of thinking") if thinking.is_a?(Hash)
          return problem(path, ONE_FORM) unless thinking.is_a?(Hash) && thinking.size == 1 &&
                                                THINKING.include?(thinking.keys.first)

          form, value = thinking.first
          return need(EFFORTS.include?(value), "#{path}/effort", "is low, medium or high") if form == "effort"

          need(integer?(value, 1), "#{path}/budget", "is an Integer of at least 1")
        end

        def fallbacks!(fallbacks, model)
          return unless list!(fallbacks, "/llm/fallbacks")

          seen = [model].compact
          fallbacks.each_with_index do |fallback, index|
            path = "/llm/fallbacks/#{index}"
            next unless object!(fallback, path)

            fields!(fallback, path, FALLBACK_FIELDS, "a field of a fallback")
            reference = model!(fallback, path)
            next if reference.nil?
            next problem(path, "repeats the model or an earlier fallback") if seen.include?(reference)

            seen << reference
          end
        end

        def taken!(provider, model, settings, path)
          return unless @models

          profile = Smith::Models.find_or_infer(model, provider:)
          model = shown(model) # as a line shows it
          if settings.key?("temperature")
            need(profile.accepts_temperature, "#{path}/temperature", "#{model} does not take a temperature")
          end
          if settings.key?("max_output_tokens")
            need(Providers::OutputLimit.supported?(provider), "#{path}/max_output_tokens",
                 "Smith sets no output limit for #{provider}")
          end
          thinking_taken!(profile, model, settings["thinking"].keys.first, "#{path}/thinking") if
            settings.key?("thinking")
        end

        def thinking_taken!(profile, model, form, path)
          return problem(path, "#{model} does not think") if profile.thinking_shape.nil?

          takes = TAKES[profile.thinking_shape]
          return if takes.nil? || form == takes

          problem("#{path}/#{form}", "#{model} takes a thinking #{takes}, not #{form == "effort" ? "an" : "a"} #{form}")
        end
      end
    end
  end
end
