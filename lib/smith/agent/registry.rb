# frozen_string_literal: true

require "dry-container"

module Smith
  class Agent
    module Registry
      extend Dry::Container::Mixin

      def self.find(name)
        key = name.to_sym
        key?(key) ? resolve(key) : nil
      end

      def self.clear!
        @_container&.clear
      end

      def self.fetch!(name, workflow_class: nil, transition_name: nil, role: :agent)
        key = name.to_sym
        return resolve(key) if key?(key)

        details = []
        details << "workflow #{workflow_class}" if workflow_class
        details << "transition :#{transition_name}" if transition_name
        suffix = details.empty? ? "" : " for #{details.join(', ')}"

        raise Smith::WorkflowError, "unresolved #{role} :#{key}#{suffix}"
      end
    end
  end
end
