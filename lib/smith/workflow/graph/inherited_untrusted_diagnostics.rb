# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # A nested workflow's agents, at any depth, are refused a key the
      # nesting workflow marks untrusted. A key a nested workflow marks
      # untrusted itself is in that workflow's own report, so it is left out
      # here. A child run inherits only the keys its `input:` passes under
      # the same names, which readiness cannot see, so past a map, call or
      # spawn the refusal is a warning.
      class InheritedUntrustedDiagnostics
        extend Dry::Initializer

        param :graph
        # Report entries ({ transition:, workflow_class:, label: }) for the
        # workflows this one nests, and the graphs the readiness walk built.
        option :entries
        option :graphs

        def to_a
          keys = UntrustedInputDiagnostic.declared_keys(graph.workflow_class)
          return [] if keys.empty?

          entries.flat_map do |entry|
            runs = entry.fetch(:transition).child_runs?
            reads(entry.fetch(:workflow_class), keys, {}, runs).map { |read| diagnostic(entry, *read) }
          end
        end

        private

        # [binding, key, runs] for each agent that reads a key, where runs
        # says a map, call or spawn lies on the way to it.
        def reads(workflow_class, keys, seen, runs)
          nested_graph = graphs[workflow_class]
          return [] if nested_graph.nil? || seen.key?([workflow_class, keys, runs])

          seen[[workflow_class, keys, runs]] = true
          keys -= UntrustedInputDiagnostic.declared_keys(workflow_class)
          return [] if keys.empty?

          agent_reads(nested_graph, keys, runs) + inner_reads(nested_graph, keys, seen, runs)
        end

        def inner_reads(nested_graph, keys, seen, runs)
          inner = nested_graph.reachable_transitions.select { _1.nested? || _1.child_runs? }
          inner.flat_map { reads(_1.target_workflow_class, keys, seen, runs || _1.child_runs?) }
        end

        def agent_reads(nested_graph, keys, runs)
          RuntimeBindingDiagnostics.new(nested_graph).agent_bindings.filter_map do |binding|
            key = (UntrustedInputDiagnostic.context_inputs(binding.fetch(:agent)) & keys).first
            [binding, key, runs] if key
          end
        end

        def diagnostic(entry, binding, key, runs)
          name = entry.fetch(:transition).name
          label = entry.fetch(:label)
          Diagnostic.new(
            severity: runs ? :warning : :error, code: :nested_untrusted_agent_input, transition: name,
            target: label, message: "Transition #{ref(name)} #{runs ? "starts runs of" : "nests"} #{label}, where " \
                                    "#{binding.fetch(:role)} #{ref(binding.fetch(:agent))} on transition " \
                                    "#{ref(binding.fetch(:transition).name)} declares #{ref(key)}, which this " \
                                    "workflow marks untrusted, as an input#{" (refused if input: passes it)" if runs}.",
            suggestion: UntrustedInputDiagnostic.suggestion(key)
          )
        end

        def ref(value) = Reference.format(value)
      end
    end
  end
end
