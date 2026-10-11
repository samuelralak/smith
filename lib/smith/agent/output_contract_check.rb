# frozen_string_literal: true

module Smith
  class Agent
    # The problems an agent's `output_contract` finds in its output, as
    # "path: problem" lines. A contract's `call(hash)` returns true or false,
    # or a result answering `success?` and `errors`: a Hash of messages by
    # key (nested as deep as the output), an Array of messages, or anything
    # with `to_h` giving such a Hash (as dry-validation's errors do). A
    # failure with no messages still counts.
    module OutputContractCheck
      FAILED = "/: fails the output contract"

      module_function

      def problems(contract, output)
        return [] unless contract

        verdict = contract.call(output)
        return verdict ? [] : [FAILED] if [true, false].include?(verdict)
        return [] if readable!(verdict).success?

        lines = messages(verdict.respond_to?(:errors) ? verdict.errors : nil)
        lines.empty? ? [FAILED] : lines.first(OutputFailure::MAX_PROBLEMS)
      end

      def readable!(verdict)
        return verdict if verdict.respond_to?(:success?)

        raise WorkflowError, "output_contract must return true, false, or a result answering success? and errors"
      end

      def messages(errors)
        case errors
        when Hash then lines(errors)
        when Array then errors.map { |message| "/: #{message}" }
        when nil then []
        else errors.respond_to?(:to_h) && !errors.is_a?(String) ? lines(errors.to_h) : ["/: #{errors}"]
        end
      end

      # { fields: { title: ["is missing"] } } becomes "/fields/title: is missing".
      def lines(errors, path = "")
        errors.flat_map do |key, value|
          at = key.nil? ? path : "#{path}/#{key}"
          next lines(value, at) if value.is_a?(Hash)

          Array(value).map { |message| "#{at.empty? ? "/" : at}: #{message}" }
        end
      end
    end
  end
end
