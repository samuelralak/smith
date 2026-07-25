# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module BoundedCompletionControls
      RESERVED_TOOL_PARAM_KEYS = %w[
        parallel_tool_calls tool_choice tool_config toolConfig tools
      ].freeze

      private_constant :RESERVED_TOOL_PARAM_KEYS

      private

      def append_budget_rejections(tool_calls, allowance)
        error = nil
        Thread.handle_interrupt(Object => :never) do
          tool_calls.each_value do |tool_call|
            begin
              run_callbacks(:before_message, :new_message)
            rescue Exception => e # rubocop:disable Lint/RescueException
              error ||= e
            end

            begin
              add_tool_result_message(tool_call, budget_rejection(allowance))
            rescue Exception => e # rubocop:disable Lint/RescueException
              error ||= e
            end
          end
        end
        raise error if error
      end

      def budget_rejection(allowance)
        {
          error: {
            code: "tool_call_budget_exhausted",
            message: "Tool call was not executed. Complete from available tool results.",
            remaining: allowance.remaining
          }
        }
      end

      def validated_tool_calls(response)
        ExecutionBatchCollection.capture(response.tool_calls)
      end

      def reject_finalization_violation(tool_calls, state)
        append_budget_rejections(tool_calls, state.allowance)
        raise BoundedCompletionError, "provider requested a tool during tool-disabled budget finalization"
      end

      def validate_supported_tools!
        unsupported = tools.values.grep_v(Smith::Tool)
        return if unsupported.empty?

        names = unsupported.map(&:name).sort.join(", ")
        raise BoundedCompletionError,
              "tool_budget_exhaustion :complete requires Smith::Tool bindings; unsupported: #{names}"
      end

      def validate_reserved_params!
        keys = params.respond_to?(:keys) ? params.keys.map(&:to_s) : []
        reserved = keys & RESERVED_TOOL_PARAM_KEYS
        return if reserved.empty?

        raise BoundedCompletionError,
              "bounded completion reserves provider tool params: #{reserved.sort.join(", ")}"
      end

      def with_bounded_tool_call_preference(remaining)
        return yield unless tool_call_cardinality_supported?

        original_calls = tool_prefs[:calls]
        begin
          tool_prefs[:calls] = remaining > 1 ? :many : :one
          yield
        ensure
          tool_prefs[:calls] = original_calls
        end
      end

      def tool_call_cardinality_supported?
        current_params = params || {}
        mode = current_params[:openai_api_mode] || current_params["openai_api_mode"]
        return true if mode.to_s == "responses"

        selected_model = respond_to?(:model) ? model : nil
        selected_model&.supports?(:parallel_tool_calls) || false
      end

      def with_tools_disabled
        original_tools = tools.dup
        original_preferences = tool_prefs.dup
        tools.clear
        tool_prefs[:choice] = :none
        tool_prefs[:calls] = tool_call_cardinality_supported? ? :one : nil
        yield
      ensure
        tools.replace(original_tools) if original_tools
        tool_prefs.replace(original_preferences) if original_preferences
      end

      def with_sequential_tool_execution
        original = @concurrency
        @concurrency = nil
        yield
      ensure
        @concurrency = original
      end
    end
  end
end
