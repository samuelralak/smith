# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      # An in-process child (a nested workflow, or a child run the launcher
      # runs in process) that reaches a step that waits, or a nested
      # workflow that launches runs of its own.
      module WaitingChildDiagnostic
        def self.build(transition, label)
          runs = transition.child_runs?
          verb = runs ? "starts in-process runs of" : "nests"
          Diagnostic.new(
            severity: :error, code: :nested_workflow_waits, transition: transition.name, target: label,
            message: "Transition #{Reference.format(transition.name)} #{verb} #{label}, " \
                     "which reaches a step that waits#{" or launches runs of its own" unless runs}.",
            suggestion: "An in-process child cannot wait#{" or launch" unless runs}; move the step into the parent " \
                        "workflow#{", or use a launcher that queues children" if runs}."
          )
        end
      end
    end
  end
end
