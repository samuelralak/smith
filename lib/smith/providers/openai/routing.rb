# frozen_string_literal: true

require "ruby_llm"

module Smith
  module Providers
    module OpenAI
      # Prepended onto RubyLLM::Providers::OpenAI. Intercepts the chat
      # `complete` call and routes to /v1/responses when the rendered
      # payload's `openai_api_mode` hint (set by the normalizer via
      # `chat.with_params(openai_api_mode: :responses)`) requests it.
      #
      # Does NOT rename `RubyLLM::Providers::OpenAI::Chat#completion_url`
      # (PR #770 does; Smith diverges to keep the surface narrower).
      # The instance_of? check prevents routing on OpenAI-compatible
      # subclasses (OpenRouter, Azure, Bedrock).
      #
      # The full /v1/responses payload assembly lives in
      # Smith::Providers::OpenAI::Responses (vendored from
      # crmne/ruby_llm PR #770 at SHA a84517db65d3774c6b129dc88032fe32c8dbc722).
      # When the PR merges upstream, Smith bumps the ruby_llm dep and
      # deletes the vendored files. The defined? guard in
      # `route_via_responses` keeps the routing safe even if a host pins
      # an older Smith without the vendored adapter, raising a clear
      # NotImplementedError rather than silently falling through to
      # chat-completions (which would still fail with the original
      # tools+reasoning combo error).
      module Routing
        def complete(messages, tools:, temperature:, model:, params: {}, headers: {},
                     schema: nil, thinking: nil, tool_prefs: nil, &)
          mode = params[:openai_api_mode] || params["openai_api_mode"]
          if mode.to_s == "responses" && instance_of?(::RubyLLM::Providers::OpenAI)
            route_via_responses(
              messages,
              tools: tools, temperature: temperature, model: model,
              params: params.except(:openai_api_mode, "openai_api_mode"),
              headers: headers, schema: schema, thinking: thinking,
              tool_prefs: tool_prefs, &
            )
          else
            super
          end
        end

        private

        def route_via_responses(messages, **, &)
          if defined?(Smith::Providers::OpenAI::Responses)
            Smith::Providers::OpenAI::Responses.complete(self, messages, **, &)
          else
            raise NotImplementedError,
                  "Smith::Providers::OpenAI::Responses (the /v1/responses adapter) " \
                  "is not yet vendored. PR #770 on crmne/ruby_llm tracks the upstream " \
                  "implementation. Until it lands, set Smith.config.openai_api_mode = :off " \
                  "to fall back to graceful tool-dropping when (gpt-5 + tools + thinking) " \
                  "is detected."
          end
        end
      end
    end
  end
end

# Install once at gem-require. Idempotent.
unless RubyLLM::Providers::OpenAI.ancestors.include?(Smith::Providers::OpenAI::Routing)
  RubyLLM::Providers::OpenAI.prepend(Smith::Providers::OpenAI::Routing)
end
