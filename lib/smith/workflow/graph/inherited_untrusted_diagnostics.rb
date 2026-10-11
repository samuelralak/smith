# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # A nested workflow's agents, at any depth, are refused a key the
      # nesting workflow marks untrusted. A key a nested workflow marks
      # untrusted itself is in that workflow's own report, so it is left out
      # here.
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
            reads(entry.fetch(:workflow_class), keys, {}).map { |binding, key| diagnostic(entry, binding, key) }
          end
        end

        private

        def reads(workflow_class, keys, seen)
          nested_graph = graphs[workflow_class]
          return [] if nested_graph.nil? || seen.key?([workflow_class, keys])

          seen[[workflow_class, keys]] = true
          keys -= UntrustedInputDiagnostic.declared_keys(workflow_class)
          return [] if keys.empty?

          nested = nested_graph.reachable_transitions.select(&:nested?)
          agent_reads(nested_graph, keys) + nested.flat_map { reads(_1.workflow_class, keys, seen) }
        end

        def agent_reads(nested_graph, keys)
          RuntimeBindingDiagnostics.new(nested_graph).agent_bindings.filter_map do |binding|
            key = (UntrustedInputDiagnostic.context_inputs(binding.fetch(:agent)) & keys).first
            [binding, key] if key
          end
        end

        def diagnostic(entry, binding, key)
          name = entry.fetch(:transition).name
          label = entry.fetch(:label)
          Diagnostic.new(
            severity: :error, code: :nested_untrusted_agent_input, transition: name, target: label,
            message: "Transition #{ref(name)} nests #{label}, where #{binding.fetch(:role)} " \
                     "#{ref(binding.fetch(:agent))} on transition #{ref(binding.fetch(:transition).name)} " \
                     "declares #{ref(key)}, which this workflow marks untrusted, as an input.",
            suggestion: UntrustedInputDiagnostic.suggestion(key)
          )
        end

        def ref(value) = Reference.format(value)
      end
    end
  end
end
