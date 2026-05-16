# frozen_string_literal: true

module Smith
  module Doctor
    module Checks
      # Validates that Smith.config.openai_api_mode is one of the allowed
      # values (:off | :auto). Also surfaces whether the
      # Smith::Providers::OpenAI::Responses adapter is loaded when mode
      # is :auto — if not, gpt-5 family + tools + thinking would raise
      # NotImplementedError at runtime.
      module OpenaiApiMode
        module_function

        def run(report)
          mode = Smith.config.openai_api_mode
          unless %i[off auto].include?(mode)
            report.add(
              name: "config.openai_api_mode",
              status: :fail,
              message: "openai_api_mode = #{mode.inspect} (invalid)",
              detail: "Must be :off or :auto"
            )
            return
          end

          if mode == :auto && !responses_adapter_loaded?
            report.add(
              name: "config.openai_api_mode",
              status: :warn,
              message: "openai_api_mode = :auto but Smith::Providers::OpenAI::Responses is not vendored",
              detail: "When (gpt-5 family + tools + thinking) is detected, the routing path " \
                      "raises NotImplementedError. Either: (a) set openai_api_mode = :off to fall " \
                      "back to graceful tool-dropping, or (b) vendor the Responses adapter (PR #770 " \
                      "on crmne/ruby_llm tracks the upstream effort)."
            )
          else
            report.add(
              name: "config.openai_api_mode",
              status: :pass,
              message: "openai_api_mode = #{mode.inspect}"
            )
          end
        end

        def responses_adapter_loaded?
          defined?(Smith::Providers::OpenAI::Responses)
        end
      end
    end
  end
end
