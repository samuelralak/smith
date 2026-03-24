# frozen_string_literal: true

module Smith
  module Doctor
    module Checks
      module Live
        def self.run(report)
          check_provider_config(report)
          check_model_call(report)
        end

        def self.check_provider_config(report)
          configured = ruby_llm_configured?
          report.add(
            name: "live.provider_config",
            status: configured ? :pass : :warn,
            message: configured ? "RubyLLM provider configured" : "No RubyLLM provider credentials detected",
            detail: configured ? nil : "Configure RubyLLM or set a provider API key env var"
          )
        end

        def self.check_model_call(report)
          attempt_model_call(report)
        end

        def self.attempt_model_call(report)
          response = ::RubyLLM.chat.ask("Respond with exactly: ok")
          has_content = response.respond_to?(:content) && !response.content.nil?
          report.add(
            name: "live.model_call",
            status: has_content ? :pass : :fail,
            message: has_content ? "Live model call succeeded" : "Live model call returned no content"
          )
        rescue StandardError => e
          report.add(name: "live.model_call", status: :fail, message: "Live model call failed", detail: e.message)
        end

        def self.ruby_llm_configured?
          config = ::RubyLLM.config
          return true if present?(config.openai_api_key)
          return true if present?(config.anthropic_api_key)
          return true if present?(config.gemini_api_key)

          false
        rescue StandardError
          false
        end

        def self.present?(value)
          value.is_a?(String) && !value.empty?
        end
      end
    end
  end
end
