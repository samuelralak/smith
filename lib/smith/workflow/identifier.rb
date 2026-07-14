# frozen_string_literal: true

module Smith
  class Workflow
    class Identifier
      def self.normalize(value, label:, allow_nil: false)
        return if value.nil? && allow_nil

        case value
        when String
          raise WorkflowError, "#{label} must not be blank" if value.strip.empty?

          value.dup.freeze
        when Symbol
          raise WorkflowError, "#{label} must not be blank" if value.to_s.empty?

          value
        else
          raise WorkflowError, "#{label} must be a String or Symbol"
        end
      end
    end
  end
end
