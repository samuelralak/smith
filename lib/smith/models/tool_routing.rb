# frozen_string_literal: true

require "dry-initializer"

module Smith
  module Models
    class ToolRouting
      TOOL_ENDPOINTS = %i[chat_completions responses].freeze

      private_constant :TOOL_ENDPOINTS

      extend Dry::Initializer

      option :chat
      option :profile
      option :decision_recorder

      # Whether #call sends a chat of `profile` with these tools (tools or tool
      # classes; `choice` the chat's forced tool choice) to the Responses
      # API: thinking that needs it, or a tool only it takes, or more tools
      # it takes. Runtime readiness asks this without a chat.
      def self.responses?(profile:, tools:, thinking:, choice: nil)
        return false unless profile.provider == :openai && Smith.config.openai_api_mode == :auto && tools.any?
        return true if thinking && thinking_route?(profile)

        forced = forced_endpoint(tools, choice, profile)
        return forced == :responses if forced

        compatible_count(tools, :responses, profile) > compatible_count(tools, :chat_completions, profile)
      end

      def self.thinking_route?(profile)
        !profile.tools_with_thinking_native && profile.tools_with_thinking_route == :responses
      end

      # The one endpoint that can carry a specifically forced tool.
      def self.forced_endpoint(tools, choice, profile)
        tool = forced_tool(tools, choice&.to_sym)
        return unless tool

        endpoints = TOOL_ENDPOINTS.select { |endpoint| compatible?(tool, endpoint, profile) }
        endpoints.first if endpoints.one?
      end

      def self.forced_tool(tools, choice)
        return if choice.nil? || %i[auto none required].include?(choice)

        tools.find { |candidate| !candidate.is_a?(Class) && candidate.name.to_sym == choice }
      end

      def self.compatible_count(tools, endpoint, profile) = tools.count { compatible?(_1, endpoint, profile) }

      def self.compatible?(tool, endpoint, profile)
        return true unless defined?(Smith::Tool::Compatibility)

        tool_class = tool.is_a?(Class) ? tool : tool.class
        spec = tool_class.respond_to?(:compatible_with_spec) ? tool_class.compatible_with_spec : nil
        Smith::Tool::Compatibility.allows?(spec, profile, effective_endpoint: endpoint)
      end
      private_class_method :thinking_route?, :forced_endpoint, :forced_tool, :compatible_count, :compatible?

      def call
        return unless chat.respond_to?(:tools)

        tools = chat.tools.values
        return if tools.empty?

        if self.class.responses?(profile:, tools:, thinking: thinking_active?, choice: chat.tool_prefs[:choice])
          route_via_responses
        end
        drop_incompatible_tools(tools)
      end

      private

      def route_via_responses
        return if responses_routed?

        merge_params(openai_api_mode: :responses)
        record(:routed_via_responses)
      end

      def drop_incompatible_tools(tools)
        endpoint = responses_routed? ? :responses : :chat_completions
        incompatible = tools.reject { |tool| tool_compatible_with?(tool, endpoint) }
        return if incompatible.empty?

        remaining = tools - incompatible
        forced_choice = reset_invalid_tool_choice(remaining)
        chat.with_tools(*remaining, replace: true)
        incompatible.each_with_index do |tool, index|
          record(:tool_dropped, dropped_tool_detail(tool, forced_choice, first: index.zero?))
        end
      end

      def dropped_tool_detail(tool, forced_choice, first:)
        detail = { tool: tool.class.name }
        if forced_choice && (tool.name.to_sym == forced_choice.to_sym || (forced_choice == :required && first))
          detail[:forced_choice_reset] = forced_choice
        end
        detail
      end

      def reset_invalid_tool_choice(remaining)
        choice = chat.tool_prefs[:choice]
        return unless choice
        return if %i[auto none].include?(choice)
        return if choice == :required && remaining.any?
        return if remaining.any? { |tool| tool.name.to_sym == choice.to_sym }

        chat.tool_prefs[:choice] = nil
        choice
      end

      def tool_compatible_with?(tool, endpoint) = self.class.__send__(:compatible?, tool, endpoint, profile)

      def thinking_active?
        thinking = chat.instance_variable_get(:@thinking)
        return true if thinking&.enabled?

        current_params.key?(:thinking) || current_params.key?(:reasoning) ||
          current_params.key?(:reasoning_effort)
      end

      def responses_routed?
        mode = current_params[:openai_api_mode] || current_params["openai_api_mode"]
        mode.to_s == "responses"
      end

      def current_params
        chat.instance_variable_get(:@params) || {}
      end

      def merge_params(**new_params)
        chat.with_params(**current_params, **new_params)
      end

      def record(kind, detail = nil)
        decision_recorder.call(kind, profile.model_id, detail)
      end
    end
  end
end
