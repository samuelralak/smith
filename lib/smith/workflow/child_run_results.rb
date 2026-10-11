# frozen_string_literal: true

module Smith
  class Workflow
    # Checking the results a host reports for a step's child runs, and
    # shaping them as the step collects them.
    module ChildRunResults
      STATUSES = %w[succeeded failed].freeze
      RESULT_KEYS = %i[ref status state output error].freeze
      private_constant :STATUSES, :RESULT_KEYS

      private

      # Outputs a map does not collect are dropped before the results are
      # bounded, so a large map can report states or counts.
      def collectable_results(config, payload)
        return payload if config[:kind] == :call || config[:collect] == :outputs || !payload.is_a?(Array)

        payload.map { |entry| entry.is_a?(Hash) ? entry.reject { |key, _value| key.to_s == "output" } : entry }
      end

      def checked_child_results(results, expected, kind)
        entries = results.is_a?(Array) ? results.map { child_result(_1, kind) } : nil
        unless entries && entries.map { _1[:ref] }.sort == (0...expected).to_a
          raise WorkflowError, "#{kind} results must hold one entry for each of its #{expected} children, by ref"
        end

        entries.sort_by { _1[:ref] }
      end

      def child_result(entry, kind)
        valid = entry.is_a?(Hash) && (entry.keys - RESULT_KEYS).empty? && entry[:ref].is_a?(Integer) &&
                STATUSES.include?(entry[:status]) && [entry[:state], entry[:error]].all? { short_text?(_1) }
        return entry if valid

        raise WorkflowError, "#{kind} results are { ref:, status: \"succeeded\" | \"failed\", state:, output:, " \
                             "error: }, with state and error short text"
      end

      def short_text?(value) = value.nil? || (value.is_a?(String) && value.bytesize <= 256)

      def collected_child_results(config, entries)
        return entries.first[:output] if config[:kind] == :call

        case config[:collect]
        when :outputs then entries.map { _1.slice(*RESULT_KEYS) }
        when :states then entries.map { _1.slice(:ref, :status, :state, :error) }
        else
          failed = entries.count { _1[:status] == "failed" }
          { succeeded: entries.length - failed, failed: }
        end
      end
    end
  end
end
