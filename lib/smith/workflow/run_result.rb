# frozen_string_literal: true

module Smith
  class Workflow
    # rubocop:disable Style/RedundantStructKeywordInit
    RunResult = Struct.new(:state, :output, :steps, :total_cost, :total_tokens, :context, :session_messages,
                           :tool_results, :outcome, :usage_entries, keyword_init: true) do
      def done?
        state_named?(:done)
      end

      def failed?
        state_named?(:failed)
      end

      def state_named?(name)
        state == name || state.to_s == name.to_s
      end

      def terminal_output
        output
      end

      def outcome_kind
        outcome&.dig(:kind)
      end

      def outcome_payload
        outcome&.dig(:payload)
      end

      def last_error
        steps.reverse.map { |step| step[:error] }.compact.first
      end

      def failed_transition
        failure_detail&.fetch(:transition)
      end

      def failure_detail
        failed_step = steps.reverse.find { |step| step[:error] }
        return nil unless failed_step

        {
          transition: failed_step[:transition],
          from: failed_step[:from],
          to: failed_step[:to],
          error: failed_step[:error]
        }
      end
    end
    # rubocop:enable Style/RedundantStructKeywordInit
  end
end
