# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # A map, call or spawn step needs a run launcher to start its runs.
      class RunLauncherDiagnostic
        extend Dry::Initializer

        param :graph

        def to_a
          return [] if Smith.config.run_launcher

          graph.reachable_transitions.select(&:child_runs?).map do |transition|
            kind = transition.children_config.fetch(:kind)
            Diagnostic.new(
              severity: :error, code: :run_launcher_missing, transition: transition.name,
              message: "Transition #{Reference.format(transition.name)} is a #{kind}, which starts runs through " \
                       "Smith.config.run_launcher, and none is configured.",
              suggestion: "Set Smith.config.run_launcher (Smith::Launchers::Inline runs children in process)."
            )
          end
        end
      end
    end
  end
end
