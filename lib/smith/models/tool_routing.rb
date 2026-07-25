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

      def call
        return unless chat.respond_to?(:tools)

        tools = chat.tools.values
        return if tools.empty?

        route_tools_with_thinking if thinking_active?
        route_tools_for_compatibility(tools)
        drop_incompatible_tools(tools)
      end

      private

      def route_tools_with_thinking
        return unless profile.provider == :openai
        return if profile.tools_with_thinking_native
        return unless profile.tools_with_thinking_route == :responses
        return unless Smith.config.openai_api_mode == :auto

        route_via_responses
      end

      def route_tools_for_compatibility(tools)
        return unless profile.provider == :openai
        return unless Smith.config.openai_api_mode == :auto
        return if responses_routed?

        forced_endpoint = forced_tool_endpoint(tools)
        return if forced_endpoint == :chat_completions
        return unless forced_endpoint == :responses ||
                      compatible_tool_count(tools, :responses) > compatible_tool_count(tools, :chat_completions)

        route_via_responses
      end

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

      def forced_tool_endpoint(tools)
        choice = chat.tool_prefs[:choice]&.to_sym
        return if %i[auto none required].include?(choice)

        tool = tools.find { |candidate| candidate.name.to_sym == choice }
        return unless tool

        compatible_endpoints = TOOL_ENDPOINTS.select { |endpoint| tool_compatible_with?(tool, endpoint) }
        compatible_endpoints.first if compatible_endpoints.one?
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

      def compatible_tool_count(tools, endpoint)
        tools.count { |tool| tool_compatible_with?(tool, endpoint) }
      end

      def tool_compatible_with?(tool, endpoint)
        return true unless defined?(Smith::Tool::Compatibility)

        spec = tool.class.respond_to?(:compatible_with_spec) ? tool.class.compatible_with_spec : nil
        Smith::Tool::Compatibility.allows?(spec, profile, effective_endpoint: endpoint)
      end

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
