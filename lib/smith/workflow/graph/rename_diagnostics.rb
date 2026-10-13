# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      # Renames (renamed_state, renamed_transition) found wanting before a
      # run restores through one: a rename leading to no name the workflow
      # declares is an error, as a run persisted under its old name cannot
      # restore; one whose old name the workflow still declares is a
      # warning, as a run persisted under that name stays there.
      # `O(R·(S + T))` for `R` renames.
      class RenameDiagnostics
        attr_reader :graph

        def initialize(graph)
          @graph = graph
        end

        def to_a
          workflow = graph.workflow_class

          [
            *diagnostics_for(:state, workflow.renamed_states) do |name|
              [workflow.resolve_state_name(name), workflow.current_state_name(name)]
            end,
            *diagnostics_for(:transition, workflow.renamed_transitions) do |name|
              [workflow.transition_named(name), workflow.current_transition_name(name)]
            end
          ]
        end

        private

        def diagnostics_for(kind, renames)
          renames.filter_map do |old, new|
            declared, current = yield(old)
            if declared
              shadowed(kind, old, new)
            elsif current.nil?
              leads_nowhere(kind, old, new)
            end
          end
        end

        def shadowed(kind, old, new)
          Diagnostic.new(
            severity: :warning,
            code: :rename_shadowed,
            kind => old,
            message: "Renamed #{kind} #{old.inspect} is still declared, so a run persisted in it stays there " \
                     "rather than moving to #{new.inspect}.",
            suggestion: "Drop the rename, or move such runs with persistence_schema_version and migrate_from."
          )
        end

        def leads_nowhere(kind, old, new)
          Diagnostic.new(
            severity: :error,
            code: :"renamed_to_unknown_#{kind}",
            kind => old,
            message: "Renamed #{kind} #{old.inspect} leads through #{new.inspect} to no #{kind} this workflow " \
                     "declares, so a run persisted in it cannot restore.",
            suggestion: "Declare #{kind} #{new.inspect} or rename #{old.inspect} to a declared #{kind}."
          )
        end
      end
    end
  end
end
