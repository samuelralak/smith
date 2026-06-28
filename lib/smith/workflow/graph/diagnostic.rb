# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      class Diagnostic
        attr_reader :severity, :code, :message, :state, :transition, :target, :suggestion

        def initialize(**attributes)
          @severity = attributes.fetch(:severity)
          @code = attributes.fetch(:code)
          @message = attributes.fetch(:message)
          @state = attributes[:state]
          @transition = attributes[:transition]
          @target = attributes[:target]
          @suggestion = attributes[:suggestion]
        end

        def to_h
          {
            severity: severity,
            code: code,
            message: message,
            state: state,
            transition: transition,
            target: target,
            suggestion: suggestion
          }.compact
        end
      end
    end
  end
end
