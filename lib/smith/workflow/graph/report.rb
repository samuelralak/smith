# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      class Report
        attr_reader :status, :workflow_class, :initial_state, :states, :transitions, :diagnostics, :metrics

        def initialize(**attributes)
          @status = attributes.fetch(:status)
          @workflow_class = attributes.fetch(:workflow_class)
          @initial_state = attributes.fetch(:initial_state)
          @states = attributes.fetch(:states)
          @transitions = attributes.fetch(:transitions)
          @diagnostics = attributes.fetch(:diagnostics)
          @metrics = attributes.fetch(:metrics)
        end

        def valid?
          errors.empty?
        end

        def errors
          diagnostics.select { |diagnostic| diagnostic.severity == :error }
        end

        def warnings
          diagnostics.select { |diagnostic| diagnostic.severity == :warning }
        end

        def suggestions
          diagnostics.map(&:suggestion).compact.uniq
        end

        def to_h
          {
            status: status,
            workflow_class: workflow_class,
            initial_state: initial_state,
            states: states,
            transitions: transitions.map(&:to_h),
            diagnostics: diagnostics.map(&:to_h),
            suggestions: suggestions,
            metrics: metrics
          }
        end
      end
    end
  end
end
