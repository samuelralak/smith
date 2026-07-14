# frozen_string_literal: true

require "dry-initializer"

require_relative "runtime_readiness_report_builder"

module Smith
  class Workflow
    class Graph
      class RuntimeReadinessTraversal
        extend Dry::Initializer

        param :graph
        option :visited, default: proc {}

        def report
          initialize_walk
          inspect_graphs
          @reports.fetch(graph.workflow_class)
        end

        private

        def initialize_walk
          @states = {}.compare_by_identity
          @reports = {}.compare_by_identity
          @graphs = {}.compare_by_identity
          @nested_transitions = {}.compare_by_identity
          @cycle_transitions = {}.compare_by_identity
          visited_workflows.each { @states[_1] = :visiting }
          @graphs[graph.workflow_class] = graph
          @states[graph.workflow_class] = :visiting
        end

        def inspect_graphs
          frames = [frame_for(graph)]
          until frames.empty?
            frame = frames.last
            if frame.fetch(:index) >= frame.fetch(:transitions).length
              complete_graph(frame.fetch(:graph))
              frames.pop
              next
            end

            transition = next_transition(frame)
            visit_child(frame.fetch(:graph), transition, frames)
          end
        end

        def frame_for(current_graph)
          {
            graph: current_graph,
            transitions: nested_transitions_for(current_graph),
            index: 0
          }
        end

        def next_transition(frame)
          transition = frame.fetch(:transitions).fetch(frame.fetch(:index))
          frame[:index] += 1
          transition
        end

        def visit_child(parent_graph, transition, frames)
          workflow_class = transition.workflow_class
          case @states[workflow_class]
          when :visiting then mark_cycle(parent_graph, transition)
          when :done then nil
          else
            child_graph = graph_for(workflow_class)
            @states[workflow_class] = :visiting
            frames << frame_for(child_graph)
          end
        end

        def complete_graph(current_graph)
          workflow_class = current_graph.workflow_class
          @reports[workflow_class] = RuntimeReadinessReportBuilder.new(
            current_graph,
            reports: @reports,
            cycle_transitions: cycles_for(current_graph)
          ).call
          @states[workflow_class] = :done
        end

        def graph_for(workflow_class)
          @graphs[workflow_class] ||= workflow_class.graph
        end

        def nested_transitions_for(current_graph)
          @nested_transitions[current_graph] ||= current_graph.transitions.values.select(&:nested?).freeze
        end

        def mark_cycle(current_graph, transition)
          cycles_for(current_graph)[transition] = true
        end

        def cycles_for(current_graph)
          @cycle_transitions[current_graph] ||= {}.compare_by_identity
        end

        def visited_workflows
          visited.respond_to?(:keys) ? visited.keys : Array(visited)
        end
      end
    end
  end
end
