# frozen_string_literal: true

require_relative "diagnostic_path"

module Smith
  class Workflow
    class Graph
      class Diagnostic
        attr_reader :severity, :code, :state, :transition, :target, :suggestion

        def initialize(**attributes)
          @severity = attributes.fetch(:severity)
          @code = attributes.fetch(:code)
          @message = attributes.fetch(:message)
          @path = attributes[:path]
          @state = attributes[:state]
          @transition = attributes[:transition]
          @target = attributes[:target]
          @suggestion = attributes[:suggestion]
        end

        def message
          return @message unless @path
          return @rendered_message if defined?(@rendered_message)

          @rendered_message = String.new.tap do |rendered|
            @path.each_label { |label| rendered << "Nested workflow #{label}: " }
            rendered << @message
          end.freeze
        end

        def nested(label:, code:, transition:, target:)
          self.class.new(
            severity: severity,
            code: code,
            message: @message,
            path: DiagnosticPath.new(label:, tail: @path),
            state: state,
            transition: transition,
            target: target,
            suggestion: suggestion
          )
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
