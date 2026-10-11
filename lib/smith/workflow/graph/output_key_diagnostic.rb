# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # A step's `output_to:` key, or an await's `into:` key, that an explicit
      # `persist` list leaves out fails the step at runtime.
      class OutputKeyDiagnostic
        extend Dry::Initializer

        option :transition
        option :workflow_class

        def call
          option, key = output_key
          return unless key

          keys = persisted_keys
          return if keys.nil? || keys.include?(key)

          Diagnostic.new(
            severity: :error, code: :"#{option}_not_persisted", transition: transition.name, target: key,
            message: "Transition #{Reference.format(transition.name)} writes #{Reference.format(key)} " \
                     "(#{option}:), which the context's persist list leaves out.",
            suggestion: "Add #{Reference.format(key)} to the context's persist list."
          )
        end

        private

        def output_key
          return [:output_to, transition.output_to] if transition.output_to

          into = transition.await_config&.fetch(:into, nil)
          [:await_into, into] if into
        end

        # The explicit list, or nil when the workflow has none or uses
        # `persist :auto`.
        def persisted_keys
          manager = workflow_class.context_manager if workflow_class.respond_to?(:context_manager)
          return unless manager.respond_to?(:persist)
          return if manager.respond_to?(:persist_mode) && manager.persist_mode == :auto

          keys = manager.persist
          keys.empty? ? nil : keys
        end
      end
    end
  end
end
